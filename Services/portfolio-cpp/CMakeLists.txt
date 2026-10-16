# Same build as the Makefile, for CMake users (CLion, VS Code CMake Tools).
cmake_minimum_required(VERSION 3.20)
project(portfolio_cpp LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

include(FetchContent)
FetchContent_Declare(httplib
    URL https://github.com/yhirose/cpp-httplib/archive/refs/tags/v0.18.3.tar.gz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
FetchContent_Declare(json
    URL https://github.com/nlohmann/json/releases/download/v3.11.3/json.tar.xz
    DOWNLOAD_EXTRACT_TIMESTAMP TRUE)
set(HTTPLIB_USE_OPENSSL_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_ZLIB_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
set(HTTPLIB_USE_BROTLI_IF_AVAILABLE OFF CACHE BOOL "" FORCE)
FetchContent_MakeAvailable(httplib json)

find_package(Threads REQUIRED)

add_library(portfolio STATIC src/optimizer.cpp src/risk.cpp src/tracking.cpp src/inputs.cpp)
target_include_directories(portfolio PUBLIC src)
target_link_libraries(portfolio PUBLIC nlohmann_json::nlohmann_json httplib::httplib Threads::Threads)

add_executable(portfolio-cpp src/main.cpp)
target_link_libraries(portfolio-cpp PRIVATE portfolio httplib::httplib Threads::Threads)

enable_testing()
add_executable(portfolio-tests tests/tests.cpp)
target_link_libraries(portfolio-tests PRIVATE portfolio)
add_test(NAME portfolio-tests COMMAND portfolio-tests)
