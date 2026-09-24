# VibeRDPCore: the flat C API over FreeRDP that the macOS client links
# FreeRDP comes from the prefix of core/scripts/build-freerdp.sh; core/scripts/build-core.sh builds and tests this project
cmake_minimum_required(VERSION 3.23)
project(VibeRDPCore LANGUAGES C)

option(VRC_BUILD_TESTS "Build the VibeRDPCore tests" ON)
option(VRC_SANITIZE "Instrument the core and its tests with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(VRC_SANITIZE)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

find_package(FreeRDP-Client 3 CONFIG REQUIRED)

add_library(VibeRDPCore STATIC src/session.c)
target_include_directories(VibeRDPCore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_link_libraries(VibeRDPCore PRIVATE freerdp-client)
# FreeRDP headers come from an imported target and count as system headers: the strict warnings hit only our code
target_compile_options(VibeRDPCore PRIVATE -Wall -Wextra -Werror)

if(VRC_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
