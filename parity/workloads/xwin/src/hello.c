/* Windows x64 console program against the Microsoft CRT and Windows SDK headers and libraries that xwin lays out. */
#include <stdio.h>
#include <windows.h>

int main(void)
{
    printf("hello from xwin sdk tick=%d\n", GetTickCount64() > 0);
    return 43;
}
