# Session tests run against local fake servers: no RDP host is needed
# HOME points into the build tree, so nothing the engine writes reaches the real home folder,
# and Kerberos reads no configuration of this Mac
set(VRC_TEST_HOME ${CMAKE_CURRENT_BINARY_DIR}/home)
file(MAKE_DIRECTORY ${VRC_TEST_HOME})
set(VRC_TEST_ENVIRONMENT "HOME=${VRC_TEST_HOME}" "KRB5_CONFIG=/dev/null")
if(VRC_SANITIZE)
  # To symbolize a report the sanitizer runs atos against the live process, which waits for debugger permission
  # and hangs the test; the raw addresses resolve offline: atos -o <binary> -l 0x100000000 <address>...
  list(APPEND VRC_TEST_ENVIRONMENT "ASAN_OPTIONS=symbolize=0")
endif()

# The TLS test server links its own OpenSSL from the prefix; the framework keeps its copy private
find_package(OpenSSL CONFIG REQUIRED)

add_executable(sessionTests sessionTests.c support.c tlsServer.c)
target_link_libraries(sessionTests PRIVATE VibeRDPCore OpenSSL::SSL OpenSSL::Crypto)
target_compile_options(sessionTests PRIVATE -Wall -Wextra -Werror)

set(VRC_SESSION_TESTS
    lifecycle
    invalidArguments
    inputNeedsAConnection
    connectRefused
    serverClosesConnection
    disconnectWhileConnecting
    destroyWhileConnecting
    hostNotFound
    resolveWithoutRequest
    certificateRejected
    certificateAccepted
    credentialsProvided
    credentialsShowTheUserName
    credentialsCancelled
    disconnectWhileCredentialsPending
    gatewayComesFirst
    certificateWithoutCallback
    disconnectWhileCertificatePending
    destroyWhileCertificatePending)
foreach(test IN LISTS VRC_SESSION_TESTS)
  add_test(NAME ${test} COMMAND sessionTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(frameTests frameTests.c ${PROJECT_SOURCE_DIR}/src/frame.c)
target_include_directories(frameTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_link_libraries(frameTests PRIVATE "-framework IOSurface" "-framework CoreFoundation")
target_compile_options(frameTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS surfaceMatchesTheDesktop emptySizeHasNoSurface)
  add_test(NAME ${test} COMMAND frameTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

# The input and pointer modules link FreeRDP themselves: the framework keeps its copy private
add_executable(inputTests inputTests.c ${PROJECT_SOURCE_DIR}/src/input.c)
target_include_directories(inputTests PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_link_libraries(inputTests PRIVATE freerdp-client)
target_compile_options(inputTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS queueKeepsOrder movesMerge closedQueueRefuses fullQueueFails takeWithLessRoom buttonFlags
                      wheelSteps keysKeepOrderWithPointer keyValid keyStateTracksKeys keyStateTakeWithLessRoom)
  add_test(NAME ${test} COMMAND inputTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(decisionTests decisionTests.c ${PROJECT_SOURCE_DIR}/src/decision.c)
target_include_directories(decisionTests PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_link_libraries(decisionTests PRIVATE freerdp-client)
target_compile_options(decisionTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS answerNeedsAQuestion answerBeforeTheWait answerFromAnotherThread abortEndsTheWait)
  add_test(NAME ${test} COMMAND decisionTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(kerberosTests kerberosTests.c ${PROJECT_SOURCE_DIR}/src/kerberos.c)
target_include_directories(kerberosTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_include_directories(kerberosTests SYSTEM PRIVATE ${VRC_KRB5_INCLUDE_DIR})
target_link_libraries(kerberosTests PRIVATE freerdp-client)
target_compile_options(kerberosTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS namesAreUnique destroyTakesTheCache destroyWithoutACache)
  add_test(NAME ${test} COMMAND kerberosTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(cliptextTests cliptextTests.c ${PROJECT_SOURCE_DIR}/src/cliptext.c)
target_include_directories(cliptextTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_options(cliptextTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS lineEndsToWindows beyondAscii brokenUtf8 lineEndsFromWindows brokenUtf16)
  add_test(NAME ${test} COMMAND cliptextTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(cliphtmlTests cliphtmlTests.c ${PROJECT_SOURCE_DIR}/src/cliphtml.c)
target_include_directories(cliphtmlTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_compile_options(cliphtmlTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS wrapsHtmlWithoutBody marksTheBodyOfAPage bodyNeedsTheWholeTagName roundTrip readsWindowsHtml
                      fragmentAndBrokenOffsets htmlWithoutHeader)
  add_test(NAME ${test} COMMAND cliphtmlTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

set(VRC_IMAGE_FRAMEWORKS "-framework CoreFoundation" "-framework CoreGraphics" "-framework ImageIO")
add_executable(clipimageTests clipimageTests.c pictures.c ${PROJECT_SOURCE_DIR}/src/clipimage.c)
target_include_directories(clipimageTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_link_libraries(clipimageTests PRIVATE ${VRC_IMAGE_FRAMEWORKS})
target_compile_options(clipimageTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS pngToDibLayout transparentGoesOverWhite imageRoundTrip readsTopDown32 readsPalette
                      readsBitfields readsV5Alpha brokenImageData)
  add_test(NAME ${test} COMMAND clipimageTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(clipfilesTests clipfilesTests.c fileTrees.c ${PROJECT_SOURCE_DIR}/src/clipfiles.c)
target_include_directories(clipfilesTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_link_libraries(clipfilesTests PRIVATE "-framework CoreFoundation")
target_compile_options(clipfilesTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS localListOfATree namesGoComposed brokenLocalLists remoteNamesAreChecked remoteFoldersAndTimes)
  add_test(NAME ${test} COMMAND clipfilesTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

# The clipboard module against a stand-in for the channel of the engine
add_executable(clipboardTests clipboardTests.c fileTrees.c ${PROJECT_SOURCE_DIR}/src/clipboard.c
                              ${PROJECT_SOURCE_DIR}/src/clipfiles.c ${PROJECT_SOURCE_DIR}/src/cliphtml.c
                              ${PROJECT_SOURCE_DIR}/src/clipimage.c ${PROJECT_SOURCE_DIR}/src/cliptext.c)
target_include_directories(clipboardTests PRIVATE ${PROJECT_SOURCE_DIR}/src ${PROJECT_SOURCE_DIR}/include)
target_link_libraries(clipboardTests PRIVATE freerdp-client ${VRC_IMAGE_FRAMEWORKS})
target_compile_options(clipboardTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS offerWaitsForMonitorReady serverPastesText serverAsksForWhatIsNotOffered serverOffersFormats
                      offerRegisteredFormats copyRegisteredFormats copyFromServer lateAnswerIsDropped copyFailures
                      detachEndsCopy offerImage imageFromServer serverReadsMacFiles copyFilesFromServer
                      cancelFileCopy)
  add_test(NAME ${test} COMMAND clipboardTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

# The clipboard channel against the echo server that build-core.sh starts; without it the test skips itself
add_executable(clipboardEchoTests clipboardEchoTests.c fileTrees.c pictures.c support.c)
target_link_libraries(clipboardEchoTests PRIVATE VibeRDPCore ${VRC_IMAGE_FRAMEWORKS})
target_compile_options(clipboardEchoTests PRIVATE -Wall -Wextra -Werror)
add_test(NAME clipboardRoundTrip COMMAND clipboardEchoTests roundTrip)
set_tests_properties(clipboardRoundTrip PROPERTIES TIMEOUT 60 SKIP_RETURN_CODE 77
                                              ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")

# Kerberos logons through NLA against the test peer that build-core.sh starts; without it they skip themselves
add_executable(kerberosLogonTests kerberosLogonTests.c support.c)
target_link_libraries(kerberosLogonTests PRIVATE VibeRDPCore)
target_compile_options(kerberosLogonTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS logonWithPrincipalName logonWithDomainPrefix wrongPasswordFailsTheLogon
                      ticketsLeaveWithTheSession)
  add_test(NAME ${test} COMMAND kerberosLogonTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 SKIP_RETURN_CODE 77 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

# H.264 through the VideoToolbox decoder of the engine; the streams come from the encoder of VideoToolbox
add_executable(h264Tests h264Tests.c)
target_link_libraries(h264Tests PRIVATE freerdp-client)
target_compile_options(h264Tests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS avc420RoundTrip avc420CroppedFrame avc444RoundTrip avc444v2RoundTrip sizeChange badStreams)
  add_test(NAME ${test} COMMAND h264Tests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

add_executable(pointerTests pointerTests.c ${PROJECT_SOURCE_DIR}/src/pointer.c)
target_include_directories(pointerTests PRIVATE ${PROJECT_SOURCE_DIR}/src)
target_link_libraries(pointerTests PRIVATE freerdp-client)
target_compile_options(pointerTests PRIVATE -Wall -Wextra -Werror)
foreach(test IN ITEMS monochromePointer colorPointerKeepsStraightAlpha noImageWithoutWhatItNeeds)
  add_test(NAME ${test} COMMAND pointerTests ${test})
  set_tests_properties(${test} PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endforeach()

# Swift imports the module of the built framework, as the app does
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
  target_compile_options(swiftImport PRIVATE "-F$<TARGET_BUNDLE_DIR:VibeRDPCore>/..")
  add_dependencies(swiftImport VibeRDPCoreModules)
  add_test(NAME swiftImport COMMAND swiftImport)
  set_tests_properties(swiftImport PROPERTIES TIMEOUT 60 ENVIRONMENT "${VRC_TEST_ENVIRONMENT}")
endif()
