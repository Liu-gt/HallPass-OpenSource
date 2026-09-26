# libargon2（自研说明）

## 出处

票 05 原计划 vendor 上游 [phc-winner-argon2](https://github.com/P-H-C/phc-winner-argon2) 源码，
但夜间自动执行手册（`autonomous_run.md` 第 4 条）**禁止联网下载依赖**，
故本目录为按 **RFC 9106** 自研的单文件 Argon2 实现（`argon2.h` / `argon2.cpp`），仅依赖 C++17 标准库。

## 正确性基线

入库前已在本机（macOS arm64, Apple clang++ -O2）对 **RFC 9106 官方测试向量**验证通过
（t=3, m=32 KiB, p=4, tag=32B, password=32×0x01, salt=16×0x02, secret=8×0x03, ad=12×0x04）：

| 类型 | 期望 tag（RFC 9106） |
|---|---|
| Argon2d | `512b391b6f1162975371d30919734294f868e3be3984f3c1a13a4db9fabe4acb` |
| Argon2i | `c814d9d1dc7f37aa13f0d77f2494bda1c8de6b016dd388d29952a4c4672b6ce8` |
| Argon2id | `0d640df58d78766c08c037a34a8b53c9d01ef0452d75b65eb52520e96b01e659` |

设备端回归测试见 `entry/src/ohosTest/Argon2Vector.test.ets`（经 NAPI + TaskPool 全链路）。

## 与参考实现的差异

- 仅实现 Bitwarden 所需路径：secret / associated data 恒为空，`version` 固定 0x13；
- 单线程填充（lane 内并行度为顺序处理），结果与参考实现逐字节一致；
- 参数上限校验在 NAPI 桥（`argon2napi.cpp`）做：memory ≤ 4 GiB、iterations ≤ 4096、
  parallelism ≤ 64、输入 ≤ 1 MiB、tagLen ∈ [16, 1024]，超限直接报错不分配（plan R1）。

## 许可

本项目为 GPL-3.0，本目录代码随项目以 GPL-3.0 分发。
