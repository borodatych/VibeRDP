# VibeRDPCore: the flat C API over FreeRDP that the macOS client links
# FreeRDP comes from the prefix of core/scripts/build-freerdp.sh; core/scripts/build-core.sh builds and tests this project
cmake_minimum_required(VERSION 3.24)

if(NOT VRC_VERSION)
  message(FATAL_ERROR "VRC_VERSION is not set: the core is configured by core/scripts/build-core.sh from build.env")
endif()
project(VibeRDPCore VERSION ${VRC_VERSION} LANGUAGES C)

option(VRC_BUILD_TESTS "Build the VibeRDPCore tests" ON)
option(VRC_SANITIZE "Instrument the core and its tests with AddressSanitizer and UndefinedBehaviorSanitizer" OFF)

set(CMAKE_C_STANDARD 17)
set(CMAKE_C_STANDARD_REQUIRED ON)

if(VRC_SANITIZE)
  add_compile_options(-fsanitize=address,undefined -fno-omit-frame-pointer)
  add_link_options(-fsanitize=address,undefined)
endif()

find_package(FreeRDP-Client 3 CONFIG REQUIRED)
# The Kerberos of the engine lies in the same prefix without a package of its own; the name with its folder
# cannot match krb5.h of the Kerberos framework in the SDK
find_path(VRC_KRB5_INCLUDE_DIR krb5/krb5.h NO_CMAKE_ENVIRONMENT_PATH NO_SYSTEM_ENVIRONMENT_PATH NO_CMAKE_SYSTEM_PATH
          REQUIRED)

# A dynamic framework with FreeRDP, OpenSSL and Kerberos linked in: the linker resolves their frameworks and channel
# objects here, so the app links one bundle and never repeats the dependency list of the engine
# Only the VRC API is exported: the engine symbols stay private and cannot clash with another OpenSSL or Kerberos
# in the process
set(VRC_PUBLIC_HEADER ${CMAKE_CURRENT_SOURCE_DIR}/include/VibeRDPCore/VibeRDPCore.h)
set(VRC_MODULE_MAP ${CMAKE_CURRENT_SOURCE_DIR}/framework/module.modulemap)
set(VRC_EXPORTS ${CMAKE_CURRENT_SOURCE_DIR}/framework/exports.txt)

add_library(VibeRDPCore SHARED src/session.c src/clipboard.c src/clipfiles.c src/cliphtml.c src/clipimage.c
            src/cliptext.c src/decision.c src/display.c src/frame.c src/input.c src/kerberos.c src/log.c
            src/pointer.c src/rail.c src/seam.c ${VRC_PUBLIC_HEADER} ${VRC_MODULE_MAP})
set_source_files_properties(${VRC_MODULE_MAP} PROPERTIES MACOSX_PACKAGE_LOCATION Modules)
set_target_properties(VibeRDPCore PROPERTIES
  FRAMEWORK TRUE
  FRAMEWORK_VERSION A
  PUBLIC_HEADER ${VRC_PUBLIC_HEADER}
  MACOSX_FRAMEWORK_IDENTIFIER tech.vibebrains.viberdp.core
  MACOSX_FRAMEWORK_SHORT_VERSION_STRING ${PROJECT_VERSION}
  MACOSX_FRAMEWORK_BUNDLE_VERSION ${PROJECT_VERSION}
  INSTALL_NAME_DIR @rpath
  BUILD_WITH_INSTALL_NAME_DIR ON
  LINK_DEPENDS ${VRC_EXPORTS})
target_include_directories(VibeRDPCore PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
target_include_directories(VibeRDPCore SYSTEM PRIVATE ${VRC_KRB5_INCLUDE_DIR})
target_link_libraries(VibeRDPCore PRIVATE freerdp-client "-framework IOSurface" "-framework CoreFoundation"
                      "-framework CoreGraphics" "-framework ImageIO")
target_link_options(VibeRDPCore PRIVATE "LINKER:-exported_symbols_list,${VRC_EXPORTS}" "LINKER:-dead_strip")
# FreeRDP headers come from an imported target and count as system headers: the strict warnings hit only our code
target_compile_options(VibeRDPCore PRIVATE -Wall -Wextra -Werror)

# CMake links Headers and Resources to the top of the bundle but not Modules, where compilers look for the module map
# A separate target, because compiling a consumer waits for a utility target but not for the link of a library
add_custom_target(VibeRDPCoreModules ALL
  COMMAND ${CMAKE_COMMAND} -E create_symlink Versions/Current/Modules $<TARGET_BUNDLE_DIR:VibeRDPCore>/Modules
  VERBATIM)
add_dependencies(VibeRDPCoreModules VibeRDPCore)

if(VRC_BUILD_TESTS)
  enable_testing()
  add_subdirectory(tests)
endif()
