cmake_minimum_required(VERSION 3.16)
project(dspi_room_correction LANGUAGES CXX)

# The core is deliberately dependency-free C++17.  It must build with the same
# sources on macOS today and Windows later, so nothing here may reach for a
# platform SDK, a UI framework, or a third-party library.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)
set(CMAKE_EXPORT_COMPILE_COMMANDS ON)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
    set(CMAKE_BUILD_TYPE Release CACHE STRING "" FORCE)
endif()

add_library(dspi_rc STATIC
    src/types.cpp
    src/biquad.cpp
    src/fft.cpp
    src/sweep.cpp
    src/calibration.cpp
    src/analysis.cpp
    src/target.cpp
    src/optimizer.cpp
    src/capi.cpp
)

target_include_directories(dspi_rc PUBLIC
    $<BUILD_INTERFACE:${CMAKE_CURRENT_SOURCE_DIR}/include>
)

if(MSVC)
    target_compile_options(dspi_rc PRIVATE /W4 /permissive-)
    # M_PI is not defined by default in the MSVC headers.
    target_compile_definitions(dspi_rc PUBLIC _USE_MATH_DEFINES)
else()
    target_compile_options(dspi_rc PRIVATE -Wall -Wextra -Wpedantic)
endif()

# ---------------------------------------------------------------------------
# Tests
# ---------------------------------------------------------------------------
enable_testing()

add_executable(dspi_rc_tests
    tests/test_main.cpp
    tests/test_biquad.cpp
    tests/test_sweep.cpp
    tests/test_calibration.cpp
    tests/test_analysis.cpp
    tests/test_target.cpp
    tests/test_optimizer.cpp
)
target_link_libraries(dspi_rc_tests PRIVATE dspi_rc)
target_include_directories(dspi_rc_tests PRIVATE ${CMAKE_CURRENT_SOURCE_DIR}/tests)

if(MSVC)
    target_compile_options(dspi_rc_tests PRIVATE /W4)
    target_compile_definitions(dspi_rc_tests PRIVATE _USE_MATH_DEFINES)
else()
    target_compile_options(dspi_rc_tests PRIVATE -Wall -Wextra)
endif()

add_test(NAME dspi_rc_tests COMMAND dspi_rc_tests)

# ---------------------------------------------------------------------------
# CLI harness
#
# Goes through the C ABI rather than the C++ headers, so every invocation also
# exercises the boundary the application layer uses.  `corpus` doubles as the
# cross-platform determinism check in CI.
# ---------------------------------------------------------------------------
add_executable(dspi_rc_cli tools/cli.cpp)
target_link_libraries(dspi_rc_cli PRIVATE dspi_rc)
if(MSVC)
    target_compile_options(dspi_rc_cli PRIVATE /W4)
    target_compile_definitions(dspi_rc_cli PRIVATE _USE_MATH_DEFINES)
else()
    target_compile_options(dspi_rc_cli PRIVATE -Wall -Wextra)
endif()

add_test(NAME dspi_rc_corpus COMMAND dspi_rc_cli corpus)
