# Links the smoke test through the CMake packages of the prefix: the same way VibeRDPCore consumes FreeRDP
# The packages carry the channel objects and the Apple frameworks that the pkg-config files of FreeRDP omit
cmake_minimum_required(VERSION 3.23)
project(LinkCheck LANGUAGES C)

find_package(FreeRDP-Client 3 CONFIG REQUIRED)
find_package(OpenSSL CONFIG REQUIRED)

add_executable(link-check link-check.c)
target_link_libraries(link-check PRIVATE freerdp-client OpenSSL::Crypto)
