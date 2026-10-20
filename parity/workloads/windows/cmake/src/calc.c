#include <windows.h>

int calc_cpu_count(void)
{
    SYSTEM_INFO si;
    GetNativeSystemInfo(&si);
    return (int)si.dwNumberOfProcessors;
}

int calc_add(int a, int b)
{
    return a + b;
}
