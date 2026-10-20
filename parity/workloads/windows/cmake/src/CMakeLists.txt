cmake_minimum_required(VERSION 3.20)
project(aap_parity_cmake VERSION 1.0.0 LANGUAGES C CXX)

enable_testing()
add_library(calc STATIC calc.c)
add_executable(calc_app main.cpp)
target_link_libraries(calc_app PRIVATE calc)
add_test(NAME calc_app_selftest COMMAND calc_app --self-test)

install(TARGETS calc_app RUNTIME DESTINATION bin)
set(CPACK_GENERATOR ZIP)
set(CPACK_PACKAGE_FILE_NAME aap-parity-cmake)
include(CPack)
