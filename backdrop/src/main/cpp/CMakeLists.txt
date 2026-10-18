# the minimum version of CMake.
cmake_minimum_required(VERSION 3.5.0)
project(backdrop)

set(NATIVERENDER_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

if(DEFINED PACKAGE_FIND_FILE)
    include(${PACKAGE_FIND_FILE})
endif()

include_directories(${NATIVERENDER_ROOT_PATH})

# GLES 自渲染需要显式查找 EGL / GLESv3。
find_library(EGL-lib EGL)
find_library(GLES-lib GLESv3)

add_library(backdrop SHARED
    napi_init.cpp
    glass/glass_napi.cpp
    glass/text_layer.cpp
    glass/glass_params.cpp
    glass/gles_renderer.cpp
    glass/shared_backdrop.cpp
    glass/perf_probe.cpp
)

# GPU 计时探针（pass 前后 glFinish 串行计时，每秒随 PERF_GL 打印各 pass 耗时）：测量包才打开，
# 例如 backdrop/build-profile.json5 的 externalNativeOptions 加 "arguments": "-DGLASS_PERF_PROBE=ON"。
option(GLASS_PERF_PROBE "Per-pass GPU timer queries for glass renderers" OFF)
if(GLASS_PERF_PROBE)
    target_compile_definitions(backdrop PRIVATE GLASS_PERF_PROBE=1)
endif()

target_link_libraries(backdrop PUBLIC libace_napi.z.so)
target_link_libraries(backdrop PUBLIC libhilog_ndk.z.so)
# hitrace 打点（perf_probe.h：GL 线程帧 / 等待 / 交换，UI 线程推偏移）
target_link_libraries(backdrop PUBLIC libhitrace_ndk.z.so)
target_link_libraries(backdrop PUBLIC ${EGL-lib} ${GLES-lib} libc++_shared.so)
# SurfaceHolder / XComponent NDK + 原生窗口 + native_drawing（文字栅格化）
target_link_libraries(backdrop PUBLIC libace_ndk.z.so libnative_window.so libnative_drawing.so)
# OH_NativeImage：BuilderNode 纹理导出（RENDER_TYPE_TEXTURE）的接收端
target_link_libraries(backdrop PUBLIC libnative_image.so)
# OH_NativeVSync：出帧对齐 vsync（每周期最多一帧，见 GlesRenderer::WaitForRenderSlot）
target_link_libraries(backdrop PUBLIC libnative_vsync.so)
