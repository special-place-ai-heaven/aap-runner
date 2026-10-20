#include <windows.h>
#include <stdio.h>

int parity_twice(int v);

int main(void)
{
    wchar_t name[257];
    DWORD n = 257;
    if (!GetUserNameW(name, &n)) {
        fprintf(stderr, "hello.c: GetUserNameW failed\n");
        return 2;
    }
    printf("hello from msvc c bits=%d twice=%d user_lookup=ok\n", (int)(sizeof(void *) * 8), parity_twice(21));
    return 0;
}
