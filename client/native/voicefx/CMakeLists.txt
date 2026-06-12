# ============================================================================
# voicefx — real-time voice-effects engine for ChatPapol.
#
# Standalone build (NOT included by the windows/linux runner CMakeLists —
# see README.md for how the binary gets bundled next to the app):
#
#   Linux:   cmake -B build && cmake --build build
#   Windows: cmake -B build -G "Visual Studio 17 2022" && cmake --build build --config Release
#
# Outputs: libvoicefx.so / voicefx.dll  (+ voicefx_cli test harness)
# ============================================================================
cmake_minimum_required(VERSION 3.15)
project(voicefx LANGUAGES CXX)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_CXX_EXTENSIONS OFF)

if(NOT CMAKE_BUILD_TYPE AND NOT CMAKE_CONFIGURATION_TYPES)
  set(CMAKE_BUILD_TYPE Release CACHE STRING "Build type" FORCE)
endif()

# ---- shared library --------------------------------------------------------
add_library(voicefx SHARED
  src/voicefx.cpp
  src/effects.cpp
  src/pitch.cpp
)
target_include_directories(voicefx PUBLIC ${CMAKE_CURRENT_SOURCE_DIR}/include)
# VOICEFX_BUILD selects __declspec(dllexport) on Windows (see voicefx.h).
target_compile_definitions(voicefx PRIVATE VOICEFX_BUILD)
set_target_properties(voicefx PROPERTIES
  CXX_VISIBILITY_PRESET hidden     # only VFX_EXPORT symbols are visible
  VISIBILITY_INLINES_HIDDEN ON
  POSITION_INDEPENDENT_CODE ON
)

if(MSVC)
  target_compile_options(voicefx PRIVATE /W4 /O2)
else()
  target_compile_options(voicefx PRIVATE -Wall -Wextra -O2)
endif()

# ---- CLI test harness ------------------------------------------------------
add_executable(voicefx_cli src/voicefx_cli.cpp)
target_link_libraries(voicefx_cli PRIVATE voicefx)
if(MSVC)
  target_compile_options(voicefx_cli PRIVATE /W4)
else()
  target_compile_options(voicefx_cli PRIVATE -Wall -Wextra)
endif()
