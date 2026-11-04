cmake_minimum_required(VERSION 3.16)
project(tennis_core VERSION 1.0 LANGUAGES CXX)

# One core, every platform: portable C++17, zero third-party deps.
set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

add_library(tennis_core STATIC
  src/num.cpp
  src/geom.cpp
  src/img.cpp
  src/detect.cpp
  src/tracker_link.cpp
  src/tracker_bridge.cpp
  src/tracker_events.cpp
  src/rally.cpp
  src/session.cpp
  src/court.cpp
  src/roi.cpp
)
target_include_directories(tennis_core PUBLIC include)
if(NOT MSVC)
  target_compile_options(tennis_core PRIVATE -Wall -Wextra -O2)
endif()

if(APPLE)
  enable_language(OBJCXX)
  add_library(tennis_apple STATIC apple/infer_apple.mm)
  target_include_directories(tennis_apple PUBLIC include)
  target_link_libraries(tennis_apple PUBLIC tennis_core
    "-framework CoreML" "-framework Foundation")
  set_target_properties(tennis_apple PROPERTIES
    CXX_STANDARD 17 CXX_STANDARD_REQUIRED ON)
else()
  add_library(tennis_apple STATIC src/infer_stub.cpp)
  target_include_directories(tennis_apple PUBLIC include)
  target_link_libraries(tennis_apple PUBLIC tennis_core)
endif()

# Shared lib for the Python (ctypes) container.
add_library(tennis_shared SHARED src/c_api.cpp)
target_link_libraries(tennis_shared PRIVATE tennis_core tennis_apple)
set_target_properties(tennis_shared PROPERTIES OUTPUT_NAME "tennis_shared")

option(TENNIS_BUILD_TESTS "Build parity tests" ON)
if(TENNIS_BUILD_TESTS)
  enable_testing()
  add_executable(parity_test tests/parity_test.cpp)
  target_link_libraries(parity_test PRIVATE tennis_core)
  target_include_directories(parity_test PRIVATE tests)
  add_test(NAME parity
    COMMAND parity_test "${CMAKE_SOURCE_DIR}/fixtures")
  add_executable(court_test tests/court_test.cpp)
  target_link_libraries(court_test PRIVATE tennis_core)
  target_include_directories(court_test PRIVATE tests)
  add_test(NAME court
    COMMAND court_test "${CMAKE_SOURCE_DIR}/fixtures")
  add_executable(roi_test tests/roi_test.cpp)
  target_link_libraries(roi_test PRIVATE tennis_core)
  target_include_directories(roi_test PRIVATE tests)
  add_test(NAME roi
    COMMAND roi_test "${CMAKE_SOURCE_DIR}/fixtures")
  add_executable(multiframe_test tests/multiframe_test.cpp)
  target_link_libraries(multiframe_test PRIVATE tennis_core)
  target_include_directories(multiframe_test PRIVATE tests)
  add_test(NAME multiframe
    COMMAND multiframe_test "${CMAKE_SOURCE_DIR}/fixtures")
  add_executable(events_test tests/events_test.cpp)
  target_link_libraries(events_test PRIVATE tennis_core)
  target_include_directories(events_test PRIVATE tests)
  add_test(NAME events COMMAND events_test)
  add_executable(rally_test tests/rally_test.cpp)
  target_link_libraries(rally_test PRIVATE tennis_core)
  target_include_directories(rally_test PRIVATE tests)
  add_test(NAME rally COMMAND rally_test)
  add_executable(link_test tests/link_test.cpp)
  target_link_libraries(link_test PRIVATE tennis_core)
  target_include_directories(link_test PRIVATE tests)
  add_test(NAME link COMMAND link_test)
endif()
