# Flowcraft

Flowcraft 是面向 Linux VPS 的统一 SSH 网络管理工具，把 BBRv3 内核、TCP 参数、出口整形、状态诊断和可恢复回滚收敛到一个配置所有者中。它用于替代同时安装多套会互相覆盖 `sysctl` 与 root qdisc 的脚本。

> 当前版本：`0.3.0`。用户命令统一为 `ftcp`。内核安装会影响启动链路，请只在具有 Web/VNC 控制台、救援模式或可选旧内核的 VPS 上操作。

## 能力

- `general`：系统已有 BBR 时启用 BBR，否则回退 Cubic；使用 fq 公平排队，不限速。
- `relay`：按 RTT、带宽和内存计算 2×BDP 缓冲；使用单连接上限和可选整机总出口双层整形。
- `landing`：单连接不限速；可选总出口保护；接收缓冲按回源 RTT、发送缓冲按中转 RTT 计算。
- `fit`：用近端 iperf3 对端实测出口 policer 拐点，粗扫后细扫，并可将推荐总出口值写回 Flowcraft。
- root qdisc 回退顺序：中转使用 HTB → TBF → fq maxrate；仅总出口使用 CAKE → HTB → TBF。
- 正常 profile 使用 `2×BDP+2MiB` 缓冲余量、RAM/32 单 socket 上限和 RAM/4 全局 TCP 上限；不强制设置 `tcp_notsent_lowat`。
- 安装前快照 sysctl、默认路由、root qdisc、IPv4 优先和 RPS/RFS，支持回滚。
- 只读体检、配置冲突检查、运行状态与 TCP 重传统计。
- 可选 IPv4 地址选择优先级和支持任意 CPU 数量的 RPS/RFS 掩码。
- 在本仓库 GitHub Actions 中为 x86_64、arm64 构建标准与实验性 Max BBRv3 内核。

## 支持范围

| 能力 | 支持环境 |
| --- | --- |
| Flowcraft 调优 | 使用 systemd、`ip`、`tc`、`sysctl` 的 Linux |
| Flowcraft BBRv3 内核 | Debian 12+、Ubuntu 24.04+，x86_64/arm64 |
| 其他发行版 | 使用 `--kernel skip`，只应用系统内核支持的功能 |

首版只管理默认出口网卡的 egress，不管理 IFB ingress、多出口策略路由或隧道内层接口。不要与其他 BBR、sysctl、tc 或主机面板网络优化功能同时使用。

## 安装

使用 root 用户执行一行命令，安装后会直接进入交互式菜单：

```bash
bash <(curl -fsSL https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh)
```

以后直接运行 `ftcp` 或 `ftcp menu` 可再次打开菜单。首次推荐按“1 首次安装 → 安装内核时重启 → 7 完成安装 → 8 端口拟合”的顺序操作。项目不再集成 Speedtest/Ookla 通用测速，只保留直接服务于 policer 调优的 iperf3 单流拟合。脚本不会仅因打开菜单而修改网络。

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
ftcp fit --peer HOST --nominal MBPS [--apply] [--lift-per-flow]
                                      实测端口 policer 拐点并可应用推荐值
ftcp experimental max-throughput --yes
ftcp rollback                  恢复安装前网络状态
ftcp uninstall                 回滚并移除 Flowcraft
```

升级安装会移除旧的 `/usr/local/bin/flowcraft`、`/usr/local/sbin/flowcraft` 及过期的 `benchmark-result`，但保留 `/etc/flowcraft`、其余 `/var/lib/flowcraft` 状态与 `flowcraft.service`，从而继续使用原有配置、快照和回滚状态。Flowcraft 不会默认黑名单 `esp4`、`esp6`、`rxrpc`；安全审计只报告状态。

### 端口拐点实测

`fit` 需要目标机已经完成 Flowcraft 安装，并需要一台靠近目标机、带宽高于目标机端口的 iperf3 服务端：

```bash
sudo ftcp fit --peer 192.0.2.10 --nominal 500
sudo ftcp fit --peer 192.0.2.10 --nominal 500 --apply
```

测量阶段会临时切换 root qdisc，并在退出、中断或失败后按当前 Flowcraft 配置重建。默认用单流和 0.1% 丢包阈值识别 policer，扫描上限为 2500 Mbps；结果保存到 `/var/lib/flowcraft/fit-result`。不加 `--apply` 只记录结果，不修改持久配置。

`--apply` 会把建议值写为 Flowcraft 的总出口 HTB+fq 上限。`relay` 的 `PER_FLOW_MBPS` 默认保持不变；只有同时提供 `--lift-per-flow` 才会把单流上限提高到实测推荐值。该测试测量的是目标机到近端对端的出口能力，不代表到最终用户或跨境线路的实际速度。

## 配置与回滚

Flowcraft 使用以下独立路径：

```text
/etc/flowcraft/config.conf
/etc/sysctl.d/99-flowcraft.conf
/etc/systemd/system/flowcraft.service
/var/lib/flowcraft/
```

配置文件按白名单解析，从不通过 `source` 或 `eval` 执行。首次调优前会记录运行态快照；`rollback` 删除 Flowcraft sysctl 文件、重新加载其他 sysctl，再把快照写回运行内核。

内核回滚需要先从旧内核启动：

```bash
sudo ftcp kernel status
# 通过 GRUB/VPS 控制台启动旧内核后
sudo ftcp kernel rollback
```

Flowcraft 拒绝卸载正在运行的 Flowcraft 内核，也不会自动清除旧内核。

## 开发验证

```bash
bash -n bin/ftcp lib/flowcraft/*.sh kernel/scripts/*.sh tests/*.sh
bash tests/self-test.sh
bash tests/install-smoke.sh
sudo bash tests/network-namespace.sh
```

CI 另外执行 ShellCheck、shfmt 和 network namespace 中的 qdisc 集成测试。真实内核安装仍必须在可恢复的一次性 Debian/Ubuntu VPS 上验收；容器测试不能证明 GRUB、云厂商引导链路或重启后的内核可用性。

## 来源与许可

Flowcraft 基于四个 MIT 项目的固定源码快照进行安全筛选整合，其中端口拟合来自 tcpfit。具体 commit、来源和适配范围见 [UPSTREAMS.lock](UPSTREAMS.lock) 与 [NOTICE](NOTICE)。Flowcraft 自身使用 [MIT License](LICENSE)。
