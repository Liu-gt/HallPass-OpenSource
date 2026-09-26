/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/*
 * argon2napi —— NAPI 桥（plan D6 / ADR-0003）：仅暴露一个派生函数。
 * 参数上限校验（plan R1）：超限直接报错，不尝试分配，防内存耗尽。
 * 本函数为同步阻塞实现，调用方必须置于 TaskPool 线程（Argon2Bridge 已封装）。
 */
#include "napi/native_api.h"
#include "libargon2/argon2.h"

#include <cstring>
#include <string>

namespace {

/* plan R1 参数上限 */
constexpr uint32_t kMaxIterations = 4096;
constexpr uint32_t kMaxParallelism = 64;
constexpr uint32_t kMaxMemoryKib = 4u * 1024u * 1024u; /* 4 GiB */
constexpr size_t kMaxInputBytes = 1024u * 1024u;        /* 1 MiB */
constexpr uint32_t kMinTagLen = 16;
constexpr uint32_t kMaxTagLen = 1024;
constexpr uint32_t kMinSaltLen = 8;

struct BytesArg {
    const uint8_t* data;
    size_t length;
};

bool ReadBytesArg(napi_env env, napi_value value, BytesArg* out) {
    napi_typedarray_type type;
    size_t length = 0;
    void* data = nullptr;
    napi_value arrayBuffer;
    size_t byteOffset = 0;
    if (napi_get_typedarray_info(env, value, &type, &length, &data, &arrayBuffer, &byteOffset) != napi_ok) {
        return false;
    }
    if (type != napi_uint8_array) {
        return false;
    }
    out->data = static_cast<const uint8_t*>(data);
    out->length = length;
    return true;
}

napi_value DeriveKdf(napi_env env, napi_callback_info info) {
    size_t argc = 6;
    napi_value args[6];
    if (napi_get_cb_info(env, info, &argc, args, nullptr, nullptr) != napi_ok || argc != 6) {
        napi_throw_error(env, "EINVAL", "deriveKdf expects 6 arguments");
        return nullptr;
    }

    BytesArg salt;
    BytesArg password;
    if (!ReadBytesArg(env, args[0], &salt) || !ReadBytesArg(env, args[1], &password)) {
        napi_throw_error(env, "EINVAL", "salt/password must be Uint8Array");
        return nullptr;
    }

    double iterations = 0;
    double memoryKib = 0;
    double parallelism = 0;
    double hashLen = 0;
    if (napi_get_value_double(env, args[2], &iterations) != napi_ok ||
        napi_get_value_double(env, args[3], &memoryKib) != napi_ok ||
        napi_get_value_double(env, args[4], &parallelism) != napi_ok ||
        napi_get_value_double(env, args[5], &hashLen) != napi_ok) {
        napi_throw_error(env, "EINVAL", "numeric arguments required");
        return nullptr;
    }
    if (iterations < 1 || iterations > kMaxIterations) {
        napi_throw_error(env, "EARGON2LIMIT", "iterations out of range [1, 4096]");
        return nullptr;
    }
    if (memoryKib < 8 * parallelism || memoryKib > kMaxMemoryKib) {
        napi_throw_error(env, "EARGON2LIMIT", "memory out of range [8*p, 4GiB]");
        return nullptr;
    }
    if (parallelism < 1 || parallelism > kMaxParallelism) {
        napi_throw_error(env, "EARGON2LIMIT", "parallelism out of range [1, 64]");
        return nullptr;
    }
    if (hashLen < kMinTagLen || hashLen > kMaxTagLen) {
        napi_throw_error(env, "EARGON2LIMIT", "hashLen out of range [16, 1024]");
        return nullptr;
    }
    if (salt.length < kMinSaltLen || salt.length > kMaxInputBytes ||
        password.length > kMaxInputBytes) {
        napi_throw_error(env, "EARGON2LIMIT", "salt/password size out of range");
        return nullptr;
    }

    hallpass_argon2::Params params;
    params.password = password.data;
    params.passwordLen = password.length;
    params.salt = salt.data;
    params.saltLen = salt.length;
    params.iterations = static_cast<uint32_t>(iterations);
    params.memoryKib = static_cast<uint32_t>(memoryKib);
    params.lanes = static_cast<uint32_t>(parallelism);
    params.tagLen = static_cast<uint32_t>(hashLen);
    params.version = 0x13;
    params.type = hallpass_argon2::ARGON2ID;

    std::vector<uint8_t> tag;
    if (!hallpass_argon2::derive(params, tag)) {
        napi_throw_error(env, "EARGON2", "argon2 derive failed");
        return nullptr;
    }

    napi_value arrayBuffer;
    void* outData = nullptr;
    if (napi_create_arraybuffer(env, tag.size(), &outData, &arrayBuffer) != napi_ok) {
        napi_throw_error(env, "ENOMEM", "failed to allocate output buffer");
        return nullptr;
    }
    memcpy(outData, tag.data(), tag.size());
    napi_value result;
    if (napi_create_typedarray(env, napi_uint8_array, tag.size(), arrayBuffer, 0, &result) != napi_ok) {
        napi_throw_error(env, "ENOMEM", "failed to create output typed array");
        return nullptr;
    }
    return result;
}

napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor desc[] = {
        {"deriveKdf", nullptr, DeriveKdf, nullptr, nullptr, nullptr, napi_default, nullptr},
    };
    napi_define_properties(env, exports, sizeof(desc) / sizeof(desc[0]), desc);
    return exports;
}

napi_module g_argon2Module = {
    .nm_version = 1,
    .nm_flags = 0,
    .nm_filename = nullptr,
    .nm_register_func = Init,
    .nm_modname = "argon2",
    .nm_priv = nullptr,
    .reserved = {0},
};

} /* namespace */

extern "C" __attribute__((constructor)) void RegisterArgon2Module(void) {
    napi_module_register(&g_argon2Module);
}
