/*
 * SPDX-FileCopyrightText: 2026 Liugt
 * SPDX-License-Identifier: GPL-3.0-or-later
 */

/* Argon2 (RFC 9106) —— 实现。出处与许可声明见 argon2.h / README.md。 */
#include "argon2.h"

#include <cstring>

namespace hallpass_argon2 {
namespace {

/* ---------------- BLAKE2b ---------------- */

const uint64_t kB2bIv[8] = {
    0x6a09e667f3bcc908ULL, 0xbb67ae8584caa73bULL, 0x3c6ef372fe94f82bULL,
    0xa54ff53a5f1d36f1ULL, 0x510e527fade682d1ULL, 0x9b05688c2b3e6c1fULL,
    0x1f83d9abfb41bd6bULL, 0x5be0cd19137e2179ULL};

const uint8_t kB2bSigma[12][16] = {
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3},
    {11, 8, 12, 0, 5, 2, 15, 13, 10, 14, 3, 6, 7, 1, 9, 4},
    {7, 9, 3, 1, 13, 12, 11, 14, 2, 6, 5, 10, 4, 0, 15, 8},
    {9, 0, 5, 7, 2, 4, 10, 15, 14, 1, 11, 12, 6, 8, 3, 13},
    {2, 12, 6, 10, 0, 11, 8, 3, 4, 13, 7, 5, 15, 14, 1, 9},
    {12, 5, 1, 15, 14, 13, 4, 10, 0, 7, 6, 3, 9, 2, 8, 11},
    {13, 11, 7, 14, 12, 1, 3, 9, 5, 0, 15, 4, 8, 6, 2, 10},
    {6, 15, 14, 9, 11, 3, 0, 8, 12, 2, 13, 7, 1, 4, 10, 5},
    {10, 2, 8, 4, 7, 6, 1, 5, 15, 11, 9, 14, 3, 12, 13, 0},
    {0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15},
    {14, 10, 4, 8, 9, 15, 13, 6, 1, 12, 0, 2, 11, 7, 5, 3}};

inline uint64_t Rotr64(uint64_t x, int n) { return (x >> n) | (x << (64 - n)); }

#define B2B_G(a, b, c, d, x, y)                  \
    do {                                         \
        a = a + b + (x);                         \
        d = Rotr64(d ^ a, 32);                   \
        c = c + d;                               \
        b = Rotr64(b ^ c, 24);                   \
        a = a + b + (y);                         \
        d = Rotr64(d ^ a, 16);                   \
        c = c + d;                               \
        b = Rotr64(b ^ c, 63);                   \
    } while (0)

void Blake2bCompress(uint64_t h[8], const uint8_t block[128], bool last, uint64_t t) {
    uint64_t v[16];
    uint64_t m[16];
    for (int i = 0; i < 16; i++) {
        uint64_t w = 0;
        for (int j = 0; j < 8; j++) {
            w |= static_cast<uint64_t>(block[i * 8 + j]) << (8 * j);
        }
        m[i] = w;
    }
    for (int i = 0; i < 8; i++) {
        v[i] = h[i];
        v[8 + i] = kB2bIv[i];
    }
    v[12] ^= t;
    v[14] ^= last ? ~0ULL : 0ULL;
    for (int r = 0; r < 12; r++) {
        const uint8_t* s = kB2bSigma[r];
        B2B_G(v[0], v[4], v[8], v[12], m[s[0]], m[s[1]]);
        B2B_G(v[1], v[5], v[9], v[13], m[s[2]], m[s[3]]);
        B2B_G(v[2], v[6], v[10], v[14], m[s[4]], m[s[5]]);
        B2B_G(v[3], v[7], v[11], v[15], m[s[6]], m[s[7]]);
        B2B_G(v[0], v[5], v[10], v[15], m[s[8]], m[s[9]]);
        B2B_G(v[1], v[6], v[11], v[12], m[s[10]], m[s[11]]);
        B2B_G(v[2], v[7], v[8], v[13], m[s[12]], m[s[13]]);
        B2B_G(v[3], v[4], v[9], v[14], m[s[14]], m[s[15]]);
    }
    for (int i = 0; i < 8; i++) {
        h[i] = h[i] ^ v[i] ^ v[i + 8];
    }
}

void Blake2b(uint8_t* out, size_t outLen, const uint8_t* in, size_t inLen) {
    uint64_t h[8];
    memcpy(h, kB2bIv, 64);
    h[0] ^= 0x01010000ULL ^ static_cast<uint64_t>(outLen);
    uint64_t t = 0;
    while (inLen > 128) {
        t += 128;
        Blake2bCompress(h, in, false, t);
        in += 128;
        inLen -= 128;
    }
    uint8_t last[128];
    memset(last, 0, 128);
    memcpy(last, in, inLen);
    t += inLen;
    Blake2bCompress(h, last, true, t);
    for (size_t i = 0; i < outLen; i++) {
        out[i] = static_cast<uint8_t>(h[i / 8] >> (8 * (i % 8)));
    }
}

/* H' = blake2b_long（可变长哈希） */
void Blake2bLong(uint8_t* out, uint32_t outLen, const uint8_t* in, size_t inLen) {
    uint8_t outlenBytes[4] = {
        static_cast<uint8_t>(outLen & 0xff),
        static_cast<uint8_t>((outLen >> 8) & 0xff),
        static_cast<uint8_t>((outLen >> 16) & 0xff),
        static_cast<uint8_t>((outLen >> 24) & 0xff)};
    if (outLen <= 64) {
        std::vector<uint8_t> buf;
        buf.reserve(4 + inLen);
        buf.insert(buf.end(), outlenBytes, outlenBytes + 4);
        buf.insert(buf.end(), in, in + inLen);
        Blake2b(out, outLen, buf.data(), buf.size());
        return;
    }
    uint8_t outBuffer[64];
    std::vector<uint8_t> buf;
    buf.reserve(4 + inLen);
    buf.insert(buf.end(), outlenBytes, outlenBytes + 4);
    buf.insert(buf.end(), in, in + inLen);
    Blake2b(outBuffer, 64, buf.data(), buf.size());
    memcpy(out, outBuffer, 32);
    out += 32;
    uint32_t toProduce = outLen - 32;
    while (toProduce > 64) {
        Blake2b(outBuffer, 64, outBuffer, 64);
        memcpy(out, outBuffer, 32);
        out += 32;
        toProduce -= 32;
    }
    Blake2b(outBuffer, toProduce, outBuffer, 64);
    memcpy(out, outBuffer, toProduce);
}

/* ---------------- Argon2 核心 ---------------- */

struct Block {
    uint64_t v[128];
};

inline uint64_t FBlaMka(uint64_t x, uint64_t y) {
    const uint64_t m = 0xFFFFFFFFULL;
    const uint64_t xy = (x & m) * (y & m);
    return x + y + 2 * xy;
}

inline void BlamkaG(uint64_t& a, uint64_t& b, uint64_t& c, uint64_t& d) {
    a = FBlaMka(a, b);
    d = Rotr64(d ^ a, 32);
    c = FBlaMka(c, d);
    b = Rotr64(b ^ c, 24);
    a = FBlaMka(a, b);
    d = Rotr64(d ^ a, 16);
    c = FBlaMka(c, d);
    b = Rotr64(b ^ c, 63);
}

void BlamkaRound(uint64_t* w) { /* 16 个 64 位字 */
    BlamkaG(w[0], w[4], w[8], w[12]);
    BlamkaG(w[1], w[5], w[9], w[13]);
    BlamkaG(w[2], w[6], w[10], w[14]);
    BlamkaG(w[3], w[7], w[11], w[15]);
    BlamkaG(w[0], w[5], w[10], w[15]);
    BlamkaG(w[1], w[6], w[11], w[12]);
    BlamkaG(w[2], w[7], w[8], w[13]);
    BlamkaG(w[3], w[4], w[9], w[14]);
}

/* fill_block：R = ref ^ prev，P 双相位（列组 + 行组），next = R ^ P(R) ^ old */
void FillBlock(const Block& prev, const Block& ref, Block& next, bool withXor) {
    uint64_t r[128];
    for (int i = 0; i < 128; i++) {
        r[i] = ref.v[i] ^ prev.v[i];
    }
    for (int i = 0; i < 8; i++) {
        BlamkaRound(r + 16 * i);
    }
    for (int i = 0; i < 8; i++) {
        uint64_t t[16];
        t[0] = r[2 * i];        t[1] = r[2 * i + 1];
        t[2] = r[2 * i + 16];   t[3] = r[2 * i + 17];
        t[4] = r[2 * i + 32];   t[5] = r[2 * i + 33];
        t[6] = r[2 * i + 48];   t[7] = r[2 * i + 49];
        t[8] = r[2 * i + 64];   t[9] = r[2 * i + 65];
        t[10] = r[2 * i + 80];  t[11] = r[2 * i + 81];
        t[12] = r[2 * i + 96];  t[13] = r[2 * i + 97];
        t[14] = r[2 * i + 112]; t[15] = r[2 * i + 113];
        BlamkaRound(t);
        r[2 * i] = t[0];        r[2 * i + 1] = t[1];
        r[2 * i + 16] = t[2];   r[2 * i + 17] = t[3];
        r[2 * i + 32] = t[4];   r[2 * i + 33] = t[5];
        r[2 * i + 48] = t[6];   r[2 * i + 49] = t[7];
        r[2 * i + 64] = t[8];   r[2 * i + 65] = t[9];
        r[2 * i + 80] = t[10];  r[2 * i + 81] = t[11];
        r[2 * i + 96] = t[12];  r[2 * i + 97] = t[13];
        r[2 * i + 112] = t[14]; r[2 * i + 113] = t[15];
    }
    for (int i = 0; i < 128; i++) {
        uint64_t nv = r[i] ^ ref.v[i] ^ prev.v[i];
        if (withXor) {
            nv ^= next.v[i];
        }
        next.v[i] = nv;
    }
}

/* index_alpha：平方偏斜 + 环形窗口（参考实现语义） */
uint32_t IndexAlpha(uint32_t pass, uint32_t slice, uint32_t index, uint32_t lanes,
                    uint32_t segLen, uint32_t laneLen, uint32_t pseudoRand, bool sameLane) {
    uint32_t referenceAreaSize;
    if (pass == 0) {
        if (slice == 0) {
            referenceAreaSize = index - 1;
        } else if (sameLane) {
            referenceAreaSize = slice * segLen + index - 1;
        } else {
            referenceAreaSize = slice * segLen + ((index == 0) ? 0xFFFFFFFFu : 0u);
        }
    } else if (sameLane) {
        referenceAreaSize = laneLen - segLen + index - 1;
    } else {
        referenceAreaSize = laneLen - segLen + ((index == 0) ? 0xFFFFFFFFu : 0u);
    }
    uint64_t relativePosition = pseudoRand;
    relativePosition = (relativePosition * relativePosition) >> 32;
    relativePosition =
        referenceAreaSize - 1 - ((static_cast<uint64_t>(referenceAreaSize) * relativePosition) >> 32);
    uint32_t startPosition = 0;
    if (pass != 0) {
        startPosition = (slice == 3) ? 0 : (slice + 1) * segLen;
    }
    return (startPosition + static_cast<uint32_t>(relativePosition)) % laneLen;
}

constexpr uint32_t kSyncPoints = 4;

} /* namespace */

bool derive(const Params& params, std::vector<uint8_t>& outTag) {
    if (params.lanes == 0 || params.lanes > 0xFFFFFF || params.iterations == 0 ||
        params.tagLen == 0 || params.version != 0x13 || params.saltLen < 8 ||
        params.memoryKib < 8 * params.lanes || params.password == nullptr ||
        params.salt == nullptr) {
        return false;
    }
    const uint32_t segLen = params.memoryKib / (kSyncPoints * params.lanes);
    if (segLen < 1) {
        return false;
    }
    const uint32_t totalBlocks = segLen * kSyncPoints * params.lanes;
    const uint32_t laneLen = totalBlocks / params.lanes;

    /* H0 */
    std::vector<uint8_t> h0buf;
    h0buf.reserve(72 + params.passwordLen + params.saltLen);
    auto append32 = [&h0buf](uint32_t x) {
        h0buf.push_back(static_cast<uint8_t>(x & 0xff));
        h0buf.push_back(static_cast<uint8_t>((x >> 8) & 0xff));
        h0buf.push_back(static_cast<uint8_t>((x >> 16) & 0xff));
        h0buf.push_back(static_cast<uint8_t>((x >> 24) & 0xff));
    };
    append32(params.lanes);
    append32(params.tagLen);
    append32(params.memoryKib);
    append32(params.iterations);
    append32(params.version);
    append32(static_cast<uint32_t>(params.type));
    append32(static_cast<uint32_t>(params.passwordLen));
    h0buf.insert(h0buf.end(), params.password, params.password + params.passwordLen);
    append32(static_cast<uint32_t>(params.saltLen));
    h0buf.insert(h0buf.end(), params.salt, params.salt + params.saltLen);
    append32(0); /* secret 长度（本项目不使用） */
    append32(0); /* associated data 长度（本项目不使用） */
    uint8_t h0[64];
    Blake2b(h0, 64, h0buf.data(), h0buf.size());

    std::vector<Block> memory(totalBlocks);
    /* 初始块：B[l][0/1] = H'(H0 || LE32(0/1) || LE32(l)) */
    uint8_t seed[72];
    memcpy(seed, h0, 64);
    for (uint32_t l = 0; l < params.lanes; l++) {
        seed[64] = 0; seed[65] = 0; seed[66] = 0; seed[67] = 0;
        seed[68] = static_cast<uint8_t>(l & 0xff);
        seed[69] = static_cast<uint8_t>((l >> 8) & 0xff);
        seed[70] = static_cast<uint8_t>((l >> 16) & 0xff);
        seed[71] = static_cast<uint8_t>((l >> 24) & 0xff);
        Blake2bLong(reinterpret_cast<uint8_t*>(memory[static_cast<size_t>(l) * laneLen].v), 1024, seed, 72);
        seed[64] = 1;
        Blake2bLong(reinterpret_cast<uint8_t*>(memory[static_cast<size_t>(l) * laneLen + 1].v), 1024, seed, 72);
    }

    Block addressBlock;
    Block inputBlock;
    Block zeroBlock;
    memset(&zeroBlock.v, 0, sizeof(zeroBlock.v));
    for (uint32_t pass = 0; pass < params.iterations; pass++) {
        for (uint32_t slice = 0; slice < kSyncPoints; slice++) {
            for (uint32_t lane = 0; lane < params.lanes; lane++) {
                const bool dataIndependent = (ARGON2I == params.type) ||
                    (ARGON2ID == params.type && pass == 0 && slice < kSyncPoints / 2);
                if (dataIndependent) {
                    memset(&inputBlock.v, 0, sizeof(inputBlock.v));
                    inputBlock.v[0] = pass;
                    inputBlock.v[1] = lane;
                    inputBlock.v[2] = slice;
                    inputBlock.v[3] = totalBlocks;
                    inputBlock.v[4] = params.iterations;
                    inputBlock.v[5] = static_cast<uint64_t>(params.type);
                }
                uint32_t startingIndex = 0;
                if (pass == 0 && slice == 0) {
                    startingIndex = 2;
                    if (dataIndependent) {
                        inputBlock.v[6]++;
                        FillBlock(zeroBlock, inputBlock, addressBlock, false);
                        FillBlock(zeroBlock, addressBlock, addressBlock, false);
                    }
                }
                uint32_t currOffset = lane * laneLen + slice * segLen + startingIndex;
                uint32_t prevOffset = (currOffset % laneLen == 0)
                    ? (currOffset + laneLen - 1)
                    : (currOffset - 1);
                for (uint32_t i = startingIndex; i < segLen; i++, currOffset++, prevOffset++) {
                    if (currOffset % laneLen == 1) {
                        prevOffset = currOffset - 1;
                    }
                    uint64_t pseudoRand;
                    if (dataIndependent) {
                        if (i % 128 == 0) {
                            inputBlock.v[6]++;
                            FillBlock(zeroBlock, inputBlock, addressBlock, false);
                            FillBlock(zeroBlock, addressBlock, addressBlock, false);
                        }
                        pseudoRand = addressBlock.v[i % 128];
                    } else {
                        pseudoRand = memory[prevOffset].v[0];
                    }
                    uint32_t refLane = static_cast<uint32_t>((pseudoRand >> 32) % params.lanes);
                    if (pass == 0 && slice == 0) {
                        refLane = lane;
                    }
                    const uint32_t refIndex = IndexAlpha(pass, slice, i, params.lanes, segLen,
                        laneLen, static_cast<uint32_t>(pseudoRand & 0xFFFFFFFFULL), refLane == lane);
                    FillBlock(memory[prevOffset], memory[static_cast<size_t>(refLane) * laneLen + refIndex],
                        memory[currOffset], pass != 0);
                }
            }
        }
    }

    /* tag = H'(各 lane 末块 XOR) */
    Block blockhash;
    memcpy(&blockhash, &memory[laneLen - 1], sizeof(Block));
    for (uint32_t l = 1; l < params.lanes; l++) {
        const Block& last = memory[static_cast<size_t>(l) * laneLen + laneLen - 1];
        for (int w = 0; w < 128; w++) {
            blockhash.v[w] ^= last.v[w];
        }
    }
    outTag.assign(params.tagLen, 0);
    Blake2bLong(outTag.data(), params.tagLen, reinterpret_cast<const uint8_t*>(blockhash.v), 1024);
    return true;
}

} /* namespace hallpass_argon2 */
