# Session tests run against local fake servers: no RDP host is needed
# HOME points into the build tree, so nothing the engine writes reaches the real home folder
set(VRC_TEST_HOME ${CMAKE_CURRENT_BINARY_DIR}/home)
file(MAKE_DIRECTORY ${VRC_TEST_HOME})
set(VRC_TEST_ENVIRONMENT "HOME=${VRC_TEST_HOME}")
if(VRC_SANITIZE)
  # To symbolize a report the sanitizer runs atos against the live process, which waits for debugger permission
  # and hangs the test; the raw addresses resolve offline: atos -o <binary> -l 0x100000000 <address>...
  list(APPEND VRC_TEST_ENVIRONMENT "ASAN_OPTIONS=symbolize=0")
endif()

add_executable(sessionTests sessionTests.c support.c)
target_link_libraries(sessionTests PRIVATE VibeRDPCore)
target_compile_options(sessionTests PRIVATE -Wall -Wextra -Werror)

set(VRC_SESSION_TESTS
    lifecycle
    invalidArguments
    connectRefused
    serverClosesConnection
    disconnectWhileConnecting
    destroyWhileConnecting)
foreach(test IN LISTS VRC_SESSION_TESTS)
  add_test(NAME ${test} COMMAND sessionTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

# Swift reads the API through module.modulemap, as the app will
# swiftc accepts no UndefinedBehaviorSanitizer and CMake builds Swift only with Ninja or Xcode
if(NOT VRC_SANITIZE AND CMAKE_GENERATOR MATCHES "Ninja")
  # CMake compiles Swift for the host whatever CMAKE_OSX_ARCHITECTURES says: a one-slice build names the target itself
  list(LENGTH CMAKE_OSX_ARCHITECTURES VRC_ARCH_COUNT)
  if(VRC_ARCH_COUNT EQUAL 1)
    set(CMAKE_Swift_COMPILER_TARGET "${CMAKE_OSX_ARCHITECTURES}-apple-macosx${CMAKE_OSX_DEPLOYMENT_TARGET}")
  endif()
  enable_language(Swift)
  add_executable(swiftImport swift/main.swift)
  target_link_libraries(swiftImport PRIVATE VibeRDPCore)
  add_test(NAME swiftImport COMMAND swiftImport)
  set_tests_properties(swiftImport PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endif()
