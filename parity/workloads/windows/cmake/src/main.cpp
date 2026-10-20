#include <cstring>
#include <iostream>

extern "C" int calc_add(int a, int b);
extern "C" int calc_cpu_count(void);

int main(int argc, char **argv)
{
    if (argc > 1 && std::strcmp(argv[1], "--self-test") == 0) {
        return calc_add(2, 3) == 5 && calc_cpu_count() > 0 ? 0 : 1;
    }
    std::cout << "hello from cmake calc add=" << calc_add(2, 3) << " cpus=" << (calc_cpu_count() > 0 ? "ok" : "none") << std::endl;
    return 0;
}
