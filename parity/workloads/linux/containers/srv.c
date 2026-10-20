/* Static helper for FROM-scratch parity images (no base image, nothing pulled).
     srv hello            print a greeting with the uid the container runs as
     srv write FILE       write a marker into FILE (bind-mounted workspace)
     srv serve PORT       answer every TCP connection with an HTTP 200 'service-ok'
     srv fetch HOST PORT  print the body served by HOST:PORT (HOST is resolved like a service alias)
   fetch exits 0 only when the body is 'service-ok', so it also serves as the health check. */
#include <netdb.h>
#include <netinet/in.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/socket.h>
#include <unistd.h>

static int fetch(const char *host, const char *port)
{
    struct addrinfo hints, *ai;
    char buf[512];
    ssize_t n, len = 0;
    int fd;
    memset(&hints, 0, sizeof hints);
    hints.ai_family = AF_INET;
    hints.ai_socktype = SOCK_STREAM;
    if (getaddrinfo(host, port, &hints, &ai) != 0)
        return 3;
    fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0 || connect(fd, ai->ai_addr, ai->ai_addrlen) != 0)
        return 4;
    if (write(fd, "GET / HTTP/1.0\r\n\r\n", 18) != 18)
        return 5;
    while (len < (ssize_t)sizeof buf - 1 && (n = read(fd, buf + len, sizeof buf - 1 - (size_t)len)) > 0)
        len += n;
    buf[len] = 0;
    close(fd);
    freeaddrinfo(ai);
    if (!strstr(buf, "\r\n\r\nservice-ok"))
        return 6;
    printf("service-ok\n");
    return 0;
}

static int serve(int port)
{
    static const char reply[] = "HTTP/1.0 200 OK\r\nContent-Length: 11\r\n\r\nservice-ok\n";
    struct sockaddr_in a;
    char buf[512];
    int one = 1, s = socket(AF_INET, SOCK_STREAM, 0);
    memset(&a, 0, sizeof a);
    a.sin_family = AF_INET;
    a.sin_port = htons((unsigned short)port);
    setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
    if (bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 8) != 0)
        return 2;
    for (;;) {
        int c = accept(s, NULL, NULL);
        if (c < 0)
            continue;
        if (read(c, buf, sizeof buf) >= 0 && write(c, reply, sizeof reply - 1) < 0)
            perror("write");
        close(c);
    }
}

int main(int argc, char **argv)
{
    if (argc == 2 && !strcmp(argv[1], "hello")) {
        printf("hello from a scratch container uid=%d\n", (int)getuid());
        return 0;
    }
    if (argc == 3 && !strcmp(argv[1], "write")) {
        FILE *f = fopen(argv[2], "w");
        return f && fputs("container-wrote\n", f) >= 0 && fclose(f) == 0 ? 0 : 2;
    }
    if (argc == 3 && !strcmp(argv[1], "serve"))
        return serve(atoi(argv[2]));
    if (argc == 4 && !strcmp(argv[1], "fetch"))
        return fetch(argv[2], argv[3]);
    fprintf(stderr, "usage: srv hello | write FILE | serve PORT | fetch HOST PORT\n");
    return 64;
}
