/* C with libm, POSIX threads and OpenSSL (libssl-dev headers, libcrypto). */
#include <math.h>
#include <openssl/evp.h>
#include <pthread.h>
#include <stdio.h>

static void *worker(void *arg)
{
    *(int *)arg = 42;
    return NULL;
}

int main(int argc, char **argv)
{
    unsigned char md[EVP_MAX_MD_SIZE];
    unsigned int n = 0, i;
    int value = 0;
    pthread_t t;
    (void)argv;
    if (pthread_create(&t, NULL, worker, &value) != 0 || pthread_join(t, NULL) != 0)
        return 2;
    if (!EVP_Digest("parity", 6, md, &n, EVP_sha256(), NULL))
        return 3;
    printf("hello from c cos=%.0f thread=%d sha256=", cos((double)(argc - 1)), value);
    for (i = 0; i < n; i++)
        printf("%02x", md[i]);
    printf("\n");
    return 0;
}
