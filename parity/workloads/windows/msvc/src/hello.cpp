#include <windows.h>
#include <filesystem>
#include <iostream>
#include <numeric>
#include <stdexcept>
#include <string>
#include <vector>

int main()
{
    std::vector<int> v{1, 2, 3, 4};
    int sum = std::accumulate(v.begin(), v.end(), 0);
    std::string caught;
    try {
        throw std::runtime_error("boom");
    } catch (const std::exception &e) {
        caught = e.what();
    }
    bool cwd = !std::filesystem::current_path().empty();
    std::cout << "hello from msvc c++ bits=" << sizeof(void *) * 8 << " sum=" << sum << " caught=" << caught
              << " cwd=" << (cwd ? "ok" : "missing") << " tick=" << (GetTickCount64() > 0 ? "ok" : "zero") << std::endl;
    return 0;
}
