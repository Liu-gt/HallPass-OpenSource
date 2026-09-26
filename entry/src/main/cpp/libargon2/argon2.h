/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/*
 * Argon2 (RFC 9106) —— Argon2d / Argon2i / Argon2id。
 *
 * 出处说明（见同目录 README.md）：因夜间构建环境禁止联网 vendor 上游 libargon2，
 * 本文件为按 RFC 9106 自研的单文件实现，已在本机对 RFC 9106 官方测试向量
 * （Argon2d / Argon2i / Argon2id 各一条，t=3 m=32 p=4）验证通过后才入库。
 * 算法结构与参考实现语义一致：index_alpha 平方偏斜 + 环形窗口、
 * fill_block R = prev^ref、next_addresses 计数器、tag = blake2b_long。
 *
 * 许可：本项目为 GPL-3.0 或更新版本（SPDX: GPL-3.0-or-later），本文件随项目以同一许可分发。
 */
#ifndef HALLPASS_ARGON2_H
#define HALLPASS_ARGON2_H

#include <cstdint>
#include <cstddef>
#include <vector>

namespace hallpass_argon2 {

enum Argon2Type {
    ARGON2D = 0,
    ARGON2I = 1,
    ARGON2ID = 2
};

struct Params {
    const uint8_t* password;
    size_t passwordLen;
    const uint8_t* salt;
    size_t saltLen;
    uint32_t iterations;   /* t：遍数 */
    uint32_t memoryKib;    /* m：KiB（内部按 4p 向下取整对齐） */
    uint32_t lanes;        /* p：并行度 */
    uint32_t tagLen;       /* 输出长度（字节） */
    uint32_t version;      /* 固定 0x13（1.3） */
    Argon2Type type;       /* d / i / id */
};

/**
 * 派生 tag。参数非法（lanes/iterations 为 0、memory < 8*lanes、
 * saltLen < 8、tagLen 为 0、version 非 0x13）返回 false。
 * secret/associated data 本项目（Bitwarden）不使用，接口不设。
 */
bool derive(const Params& params, std::vector<uint8_t>& outTag);

} /* namespace hallpass_argon2 */

#endif /* HALLPASS_ARGON2_H */
