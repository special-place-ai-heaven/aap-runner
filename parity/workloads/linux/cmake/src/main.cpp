#include <iostream>

extern "C" int parity_add(int a, int b);

int main()
{
    std::cout << "parity_add(2, 3) = " << parity_add(2, 3) << '\n';
    return 0;
}
