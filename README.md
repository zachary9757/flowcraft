# Flowcraft

Flowcraft 是面向 Linux VPS 的统一 SSH 网络管理工具，把 BBRv3 内核、TCP 参数、出口整形、状态诊断和可恢复回滚收敛到一个配置所有者中。它用于替代同时安装多套会互相覆盖 `sysctl` 与 root qdisc 的脚本。

> 当前版本：`0.5.1`。用户命令统一为 `ftcp`。内核安装会影响启动链路，请只在具有 Web/VNC 控制台、救援模式或可选旧内核的 VPS 上操作。

## 角色与能力

| 角色 | 适用场景 | 默认策略 |
| --- | --- | --- |
| `general` | 通用 VPS | BBR 可用时启用 BBR，否则使用 Cubic；fq 公平排队，不限速 |
| `relay` | 中转、代理、复用连接 | 按 RTT、带宽和内存计算缓冲；支持单连接与整机总出口双层整形 |
| `landing` | 落地、回源 | 单连接不限速；可选总出口保护；接收缓冲按回源 RTT 计算 |

角色描述业务策略，`fit` 测量物理总出口，两者分开管理。`relay` 的单连接上限不应直接当作 VPS 总出口；可信拟合结果只在 30 天内且出口网卡、默认路由未变化时复用。

核心能力：

- 根据 BDP、内存和实际内核页大小生成 TCP/sysctl 配置，不降低系统已有的更高容量上限。
- 使用 HTB、TBF、CAKE 或 fq 管理默认出口，并在应用前检查 qdisc 所有权和回滚边界。
- 通过 iperf3 粗扫、细扫和最终复验识别出口 policer 拐点。
- 快照 sysctl、默认路由、root qdisc 类型、IPv4 优先级和目标出口 RPS/RFS。
- 提供只读体检、冲突检查、运行态漂移诊断和 TCP 重传统计。
- 提供 x86_64、arm64 的标准及实验性 Max BBRv3 内核构建。

## 支持范围

| 能力 | 支持环境 |
| --- | --- |
| Flowcraft 调优 | 使用 systemd、`ip`、`tc`、`sysctl` 的 Linux |
| Flowcraft BBRv3 内核 | Debian 12+、Ubuntu 24.04+，x86_64/arm64 |
| 其他发行版 | 使用 `--kernel skip`，只应用系统内核支持的功能 |

首版只管理默认出口网卡的 egress，不管理 IFB ingress、多出口策略路由或隧道内层接口。不要与其他 BBR、sysctl、tc 或主机面板网络优化功能同时使用。

## 发布模型

- `vX.Y.Z` 是 Flowcraft 程序版本，并作为 GitHub **Latest** Release；一键安装器仍从经过测试的 `main` 下载当前版本。
- `x86_64-X.Y.Z`、`arm64-X.Y.Z` 及其 `-max` 变体只发布对应架构的内核资产，不参与 Latest 程序版本判定。
- 程序升级不会自动安装内核；内核 Release 也不会替换 `/usr/local/sbin/ftcp`。

## 安装

使用 root 用户执行一行命令，安装后会直接进入交互式菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh)
```

以后直接运行 `ftcp` 或 `ftcp menu` 可再次打开菜单。面板会根据当前安装阶段和拟合结果显示“下一步”，完整顺序为：

```text
[1] 选择角色、内核和基础参数
 → 安装 BBRv3 时重启
 → [7] resume 验证内核并完成基础调优
 → [8] 实测物理总出口拐点
 → [7] status / diagnose 复核
```

使用 `--kernel skip` 时不需要重启和 `resume`，菜单 1 完成后可直接进入菜单 8。项目不集成 Speedtest/Ookla 通用测速，只保留直接服务于 policer 调优的 iperf3 拟合。仅打开菜单不会修改网络。

也可以手动克隆仓库并进行只读体检：

```bash
git clone https://github.com/zachary9757/flowcraft.git
cd flowcraft
sudo ./bin/ftcp inspect
sudo ./bin/ftcp plan --role relay --kernel skip --rtt 160 --per-flow 430 --total 2300
```

交互安装：

```bash
sudo ./bin/ftcp install
```

无人值守安装示例：

```bash
sudo ./bin/ftcp install \
  --non-interactive \
  --role relay \
  --kernel standard \
  --rtt 160 \
  --per-flow 430 \
  --total 2300 \
  --yes
```

如果选择 Flowcraft 内核，安装会在写入 `.deb` 后停止，不会自动重启：

```bash
sudo reboot
# 确认 SSH 和服务正常后
sudo ftcp resume
```

`resume` 会验证当前运行的内核版本以及 `tcp_bbr version=3`，验证失败时不会继续写网络调优配置。

### 首次构建内核 Release

仓库管理员需要先在 GitHub Actions 手动运行 **Build Flowcraft BBRv3 kernels**。之后工作流每天检查 kernel.org 最新 stable，并仅在仓库存在相应主线 patch 时构建：

- `x86_64-X.Y.Z` / `arm64-X.Y.Z`：标准内核；
- `x86_64-X.Y.Z-max` / `arm64-X.Y.Z-max`：实验性 Max 内核；
- 每个 Release 都包含 Debian 包、最终 config 和 `SHA256SUMS`。

Max 版不会出现在默认路径中，必须显式使用：

```bash
sudo ./bin/ftcp install --non-interactive --role general \
  --kernel max --experimental --yes
```

## 命令

```text
ftcp inspect [--json]          只读环境、冲突和能力检查
ftcp plan [options]            只展示计划，不修改系统
ftcp install [options]         角色向导或无人值守安装
ftcp resume                    重启后继续第二阶段
ftcp apply                     重应用配置
ftcp status                    内核、TCP、qdisc 和重传状态
ftcp diagnose                  状态及冲突诊断
ftcp profile general|relay|landing
ftcp kernel install|status|rollback
ftcp network ipv4-priority on|off
ftcp nic rps auto|off
ftcp qdisc fq|fq_codel|fq_pie|cake
ftcp security audit            只读检查 AEAD/Dirty Frag 风险面
ftcp fit [--peer HOST [--port PORT]] --nominal MBPS [--cap MBPS]
         [--from MBPS --to MBPS [--step MBPS]] [--apply] [--lift-per-flow]
                                      tcpfit sweep 实测 policer 丢包拐点
ftcp experimental max-throughput --yes
ftcp rollback                  恢复安装前网络状态
ftcp uninstall                 回滚并移除 Flowcraft
```

覆盖安装会替换程序文件并清理旧命令入口，但保留 `/etc/flowcraft`、`/var/lib/flowcraft` 和现有服务状态。升级不会自动切换内核。Flowcraft 不会默认黑名单 `esp4`、`esp6`、`rxrpc`；安全审计只报告状态。

### 端口拐点实测

`fit` 需要目标机已经完成 Flowcraft 安装。不指定 `--peer` 时，Flowcraft 会并发测量公共节点 RTT，按延迟从低到高轮换 5200–5210 端口，并用固定 1 MB 数据量确认 iperf3 服务可用。菜单中的“拟合参考带宽”只用于健康检查和安全余量，不代表已经确认的物理端口上限：

```bash
sudo ftcp fit --nominal 500
sudo ftcp fit --peer 192.0.2.10 --nominal 500
sudo ftcp fit --peer 192.0.2.10 --port 5201 --nominal 500 --apply
sudo ftcp fit --peer 192.0.2.10 --nominal 850 --cap 6000
sudo ftcp fit --peer 192.0.2.10 --nominal 850 --from 600 --to 1000 --step 20
```

自动拟合流程：

1. 在 `min(标称值, cap)` 的 40% 验证路径和对端。
2. 临时使用不限速 fq 探测单流能力；低送达量会补取样本，高带宽疑点会用多流反证。
3. 仅在不限速样本出现高丢包时进入粗扫和细扫；同一档位至少 2/3 次出现丢包跳变才确认拐点。
4. 从最后一个干净档位扣除分档余量或 3%（取较大值），再对建议速率做 3 次落地复验。

只有最终至少 2/3 次达到目标 90% 且无丢包跳变，结果才会记为 `fitted`。其余状态只记录结果，不修改持久配置。公共节点测试上限为 2500 Mbps；更高速率必须通过 `--peer` 使用近端独享服务器。

自动模式只接受 RTT 不超过 100 ms 的节点，低速健康检查失败时最多轮换三个节点。公共节点可能占线或维护；自动发现不会安装软件或修改防火墙。

每个测量档位都会先安装对应的临时 HTB，退出、中断或失败后按当前 Flowcraft 配置重建 root qdisc。结果保存在 `/var/lib/flowcraft/fit-result`，包含测量时间、出口网卡、默认路由指纹、测试范围、实际对端、端口、RTT 与是否自动选择；超过 30 天或出口上下文变化后不会自动复用。

`--apply` 会把建议值写为 Flowcraft 的总出口 HTB+fq 上限。`relay` 的 `PER_FLOW_MBPS` 默认保持不变；只有同时提供 `--lift-per-flow` 才会把单流上限提高到实测推荐值。该测试测量的是目标机到近端对端的出口能力，不代表到最终用户或跨境线路的实际速度。

## 配置与回滚

Flowcraft 使用以下独立路径：

```text
/etc/flowcraft/config.conf
/etc/sysctl.d/99-flowcraft.conf
/etc/systemd/system/flowcraft.service
/var/lib/flowcraft/
```

配置文件按白名单解析，从不通过 `source` 或 `eval` 执行。首次调优前会记录运行态快照；`rollback` 删除 Flowcraft sysctl 文件、重新加载其他 sysctl，再把快照写回运行内核。root qdisc 只能可靠恢复类型，因此首次接管前若检测到 CAKE、HTB、TBF、netem 等带参数或层级的复杂 qdisc，会直接拒绝操作，避免制造不可逆回滚承诺。IPv4 优先级只移除 Flowcraft 自己追加的规则，不改动安装前已存在的同名规则。

内核回滚需要先从旧内核启动：

```bash
sudo ftcp kernel status
# 通过 GRUB/VPS 控制台启动旧内核后
sudo ftcp kernel rollback
```

Flowcraft 拒绝卸载正在运行的 Flowcraft 内核，也不会自动清除旧内核。

## 开发验证

```bash
bash -n install.sh bin/ftcp lib/flowcraft/*.sh kernel/scripts/*.sh tests/*.sh
bash tests/self-test.sh
bash tests/install-smoke.sh
sudo bash tests/network-namespace.sh
```

CI 另外执行 ShellCheck、shfmt 和 network namespace 中的 qdisc 集成测试。真实内核安装仍必须在可恢复的一次性 Debian/Ubuntu VPS 上验收；容器测试不能证明 GRUB、云厂商引导链路或重启后的内核可用性。

## 来源与许可

Flowcraft 基于四个 MIT 项目的固定源码快照进行安全筛选整合，其中端口拟合来自 tcpfit。具体 commit、来源和适配范围见 [UPSTREAMS.lock](UPSTREAMS.lock) 与 [NOTICE](NOTICE)。Flowcraft 自身使用 [MIT License](LICENSE)。
