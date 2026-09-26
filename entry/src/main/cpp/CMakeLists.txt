cmake_minimum_required(VERSION 3.5.0)
project(argon2napi)

set(CMAKE_CXX_STANDARD 17)
set(NATIVE_ROOT_PATH ${CMAKE_CURRENT_SOURCE_DIR})

add_library(argon2 SHARED
    ${NATIVE_ROOT_PATH}/argon2napi.cpp
    ${NATIVE_ROOT_PATH}/libargon2/argon2.cpp
)

# Argon2 是内存困难 KDF：Debug HAP 默认 -O0 会让 64MiB 派生慢到不可用，
# 本库固定 -O2（plan D6/R1）。
target_compile_options(argon2 PRIVATE -O2)

target_link_libraries(argon2 PUBLIC
    ace_napi.z
    hilog_ndk.z
)
