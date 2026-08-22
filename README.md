# Flowcraft

Flowcraft 是面向 Linux VPS 的统一 SSH 网络管理工具，把 BBRv3 内核、TCP 参数、出口整形、状态诊断和可恢复回滚收敛到一个配置所有者中。它用于替代同时安装多套会互相覆盖 `sysctl` 与 root qdisc 的脚本。

> 当前版本：`0.4.1`。用户命令统一为 `ftcp`。内核安装会影响启动链路，请只在具有 Web/VNC 控制台、救援模式或可选旧内核的 VPS 上操作。

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
ftcp fit [--peer HOST [--port PORT]] --nominal MBPS [--apply] [--lift-per-flow]
ftcp fit --peer HOST --nominal MBPS --discover --ceiling MBPS [--apply]
                                      有界实测端口 policer 拐点
ftcp experimental max-throughput --yes
ftcp rollback                  恢复安装前网络状态
ftcp uninstall                 回滚并移除 Flowcraft
```

升级安装会移除旧的 `/usr/local/bin/flowcraft`、`/usr/local/sbin/flowcraft` 及过期的 `benchmark-result`，但保留 `/etc/flowcraft`、其余 `/var/lib/flowcraft` 状态与 `flowcraft.service`，从而继续使用原有配置、快照和回滚状态。Flowcraft 不会默认黑名单 `esp4`、`esp6`、`rxrpc`；安全审计只报告状态。

### 端口拐点实测

`fit` 需要目标机已经完成 Flowcraft 安装。不指定 `--peer` 时，Flowcraft 会并发测量公共节点 RTT，按延迟从低到高轮换 5200–5210 端口，并用固定 1 MB 数据量确认 iperf3 服务可用：

```bash
sudo ftcp fit --nominal 500
sudo ftcp fit --peer 192.0.2.10 --nominal 500
sudo ftcp fit --peer 192.0.2.10 --port 5201 --nominal 500 --apply
sudo ftcp fit --peer 192.0.2.10 --nominal 850 --discover --ceiling 6000
```

普通模式不再进行不限速基线测试。它先在标称值 20%（最高 200 Mbps）执行路径健康检查，再按 50%、70%、85%、100%、110%、125% 有界递增；任何档位都不得超过本次 ceiling。850 Mbps 标称值默认只会测试到 1062 Mbps。如果范围内全部干净，结果为 `clean-through-envelope`，即使提供 `--apply` 也保留原有配置。

拐点采用双信号判定：重传率超过动态阈值，或者当前吞吐效率降到低速健康基线的 90% 以下、同时新增测试速率的边际吞吐收益低于 50%。任一信号都必须在同一档位通过 2/3 复测确认，随后才进入 2% 标称带宽步长的细扫。这样既能识别 policer 丢包拐点，也能识别无明显丢包但吞吐曲线已经变平的容量拐点。

只有 `fitted`（已经通过 2/3 复测找到可信拐点）允许自动应用。`dirty-path`、`peer-too-slow`、`measurement-failed`、`shaper-failed` 和 `clean-through-envelope` 都只记录结果。安全余量根据实测干净上限计算，而不是根据输入的标称值计算；结果同时记录 `BREAK_REASON` 和最后一个干净档位的实际吞吐。

需要继续寻找高于 125% 标称值的真实极限时，必须显式使用 `--discover --ceiling`。公共节点最高允许 2500 Mbps；更高速率必须用 `--peer` 指定近端独享服务器。旧 `--cap N` 暂时兼容为 `--discover --ceiling N`，运行时会显示迁移提示。

自动模式默认只接受 RTT 不超过 100 ms 的节点；50 ms 以上会明确提示结果可能偏保守。低速健康检查发现路径脏或对端过慢时会自动换节点，最多尝试三个。公共节点由第三方免费提供，存在占线、维护或策略变化；自动发现不会安装软件，也不会修改防火墙。

每个测量档位都会先安装对应的临时 HTB，退出、中断或失败后按当前 Flowcraft 配置重建 root qdisc。结果保存在 `/var/lib/flowcraft/fit-result`，包含测试范围、实际对端、端口、RTT 与是否自动选择。

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
