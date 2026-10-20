// C++17 with libstdc++, std::thread and the standard algorithms.
#include <algorithm>
#include <iostream>
#include <numeric>
#include <string>
#include <thread>
#include <vector>

int main()
{
    std::vector<int> v{4, 1, 3, 2};
    std::sort(v.begin(), v.end());
    int sum = 0;
    std::thread t([&] { sum = std::accumulate(v.begin(), v.end(), 0); });
    t.join();
    std::string s;
    for (int x : v)
        s += std::to_string(x);
    std::cout << "hello from c++ sorted=" << s << " sum=" << sum << '\n';
    return 0;
}
