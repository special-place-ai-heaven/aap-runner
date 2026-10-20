#include <windows.h>

int parity_add(int a, int b)
{
    return a + b;
}

unsigned int parity_cpu_count(void)
{
    SYSTEM_INFO si;
    GetNativeSystemInfo(&si);
    return si.dwNumberOfProcessors;
}
