// C++23 <print>: libstdc++ 14 has it, the default g++ 13 does not.
#include <print>

int main()
{
    std::println("hello from c++23 {}", 23);
    return 0;
}
