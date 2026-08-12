# Flowcraft

Flowcraft 是面向 Linux VPS 的统一 SSH 网络管理工具，把 BBRv3 内核、TCP 参数、出口整形、状态诊断和可恢复回滚收敛到一个配置所有者中。它用于替代同时安装多套会互相覆盖 `sysctl` 与 root qdisc 的脚本。

> 当前版本：`0.1.0`。内核安装会影响启动链路，请只在具有 Web/VNC 控制台、救援模式或可选旧内核的 VPS 上操作。

## 能力

- `general`：系统已有 BBR 时启用 BBR，否则回退 Cubic；使用 fq 公平排队，不限速。
- `relay`：按 RTT、带宽和内存计算 2×BDP 缓冲；使用单连接上限和可选整机总出口双层整形。
- `landing`：单连接不限速；可选总出口保护；接收缓冲按回源 RTT、发送缓冲按中转 RTT 计算。
- root qdisc 回退顺序：中转使用 HTB → TBF → fq maxrate；仅总出口使用 CAKE → HTB → TBF。
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

以后直接运行 `flowcraft` 或 `flowcraft menu` 可再次打开菜单。首次推荐按“8 带宽测试 → 1 首次安装 → 安装内核时重启 → 7 完成安装并验收”的顺序操作。测速完成后，最近一次下载、上传、Ping 和时间会显示在主面板；Ping 仅供查看，不会被当成业务 RTT。脚本不会仅因打开菜单而修改网络。

### 新 VPS 完整调优顺序

开始前请确认 VPS 具有 Web/VNC 控制台、救援模式或可选择的旧内核。旧机器如果已安装其他 BBR、sysctl、`tc` 或主机面板网络优化工具，应先卸载旧工具；Flowcraft 检测到冲突时会停止，不会静默覆盖。

先进入 root shell，再运行一键安装命令：

```bash
sudo -i
bash <(curl -fsSL https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh)
```

安装后按照面板中的顺序操作：

```text
8 带宽测试
→ 1 首次安装 / 角色向导
→ 安装 BBRv3 内核
→ 手动重启 VPS
→ 7 完成安装、状态与诊断
→ 1 resume
→ 2 status
→ 3 diagnose
```

#### 1. 先进行带宽测试

在主菜单选择 `8`。如果系统没有测速客户端，面板会询问是否从 Debian/Ubuntu 软件源安装 `speedtest-cli`。测速结果会保存到 `/var/lib/flowcraft/benchmark-result` 并显示在主面板。

测速服务器的 Ping 只用于观察线路，不能代替角色向导中的业务 RTT。业务 RTT 应填写实际用户到中转机的延迟；落地机的回源 RTT 应填写源站或中转机到落地机的延迟。

#### 2. 选择角色和带宽参数

在主菜单选择 `1`，根据 VPS 用途选择角色：

| 角色 | 适用场景 | 限速策略 |
| --- | --- | --- |
| `general` | 建站、代理、下载或普通综合用途 VPS | BBR + fq，不限制单连接和整机出口 |
| `relay` | 跨境中转、观看机、多客户端共享节点 | 按业务 RTT 设置缓冲，可限制单连接和整机出口 |
| `landing` | 中转后端的同区域落地节点 | 不限制单连接，可设置整机出口保护 |

`relay` 常用参考值：

| 使用条件 | 稳定档 | 速度优先档 |
| --- | ---: | ---: |
| 客户端 500M 家宽 | 单连接 430 Mbps | 单连接 450 Mbps |
| 客户端 1G 家宽 | 单连接 850 Mbps | 单连接 900 Mbps |

整机总出口可按 VPS 端口填写：1G 端口建议 `900` Mbps，2.5G 端口建议 `2300` Mbps，填写 `0` 表示不限整机出口。`landing` 也可使用 `900`、`2300` 或 `0`；不确定角色时优先选择 `general`。

#### 3. 选择内核

角色向导提供三种选择：

1. Flowcraft BBRv3 标准版：Debian 12+、Ubuntu 24.04+ 的 x86_64/arm64 VPS 推荐使用。
2. 跳过内核安装：特殊厂商内核、OpenVZ/LXC、其他发行版、没有救援入口或暂时不希望重启时使用。
3. BBRv3 Max：实验选项，正常使用不要选择。

#### 4. 选择可选优化

- IPv4 优先通常选择 `N`。只在 IPv6 绕路、握手慢或连接不稳定时开启。
- RPS/RFS 通常选择 `N`。只在多核、高吞吐且单核 SoftIRQ 已成为瓶颈时开启；普通 1～2 核 VPS 保持关闭。
- 队列策略保持角色自动选择即可。使用 `relay` 双层整形时，不要再用手动 qdisc 模式覆盖整形树。

向导会显示完整变更计划。检查角色、网卡、RTT、速率、IPv4 优先和 RPS/RFS 后，输入 `y` 确认。Flowcraft 会先保存原始 sysctl、默认路由、root qdisc、IPv4 优先和 RPS/RFS 快照，再执行安装。

#### 5. 重启并完成第二阶段

选择标准 BBRv3 内核后，Flowcraft 只安装内核并写入 `pending-reboot` 阶段，不会自动重启：

```bash
reboot
```

VPS 启动并恢复 SSH 后，再次打开面板：

```bash
flowcraft
```

选择 `7`，然后选择 `1 resume`。Flowcraft 会验证目标内核和 `tcp_bbr version=3`，验证成功后才会应用角色 sysctl、拥塞控制、出口 qdisc、可选 IPv4/RPS 设置和 systemd 持久化。如果安装时选择跳过内核，这些网络调优会在首次安装阶段直接应用，不需要重启或执行 `resume`。

#### 6. 最终验收

在主菜单选择 `7`，依次运行：

```text
2 status
3 diagnose
4 security（可选，只读安全审计）
```

正常结果应显示安装阶段为 `complete`，并且 `tc`、`ip` 和 systemd 能力可用；安装 Flowcraft 标准内核时还应显示拥塞控制为 `bbr`、BBR 模块版本为 `3`。选择跳过内核时，以系统内核实际支持的 BBR 或 Cubic 为准。`relay` 启用整形后，root qdisc 可能显示为 HTB 或回退队列，这是正常现象。

也可以手动克隆仓库并进行只读体检：

```bash
git clone https://github.com/zachary9757/flowcraft.git
cd flowcraft
sudo ./bin/flowcraft inspect
sudo ./bin/flowcraft plan --role relay --kernel skip --rtt 160 --per-flow 430 --total 2300
```

交互安装：

```bash
sudo ./bin/flowcraft install
```

无人值守安装示例：

```bash
sudo ./bin/flowcraft install \
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
sudo flowcraft resume
```

`resume` 会验证当前运行的内核版本以及 `tcp_bbr version=3`，验证失败时不会继续写网络调优配置。

### 首次构建内核 Release

仓库管理员需要先在 GitHub Actions 手动运行 **Build Flowcraft BBRv3 kernels**。之后工作流每天检查 kernel.org 最新 stable，并仅在仓库存在相应主线 patch 时构建：

- `x86_64-X.Y.Z` / `arm64-X.Y.Z`：标准内核；
- `x86_64-X.Y.Z-max` / `arm64-X.Y.Z-max`：实验性 Max 内核；
- 每个 Release 都包含 Debian 包、最终 config 和 `SHA256SUMS`。

Max 版不会出现在默认路径中，必须显式使用：

```bash
sudo ./bin/flowcraft install --non-interactive --role general \
  --kernel max --experimental --yes
```

## 命令

```text
flowcraft inspect [--json]          只读环境、冲突和能力检查
flowcraft plan [options]            只展示计划，不修改系统
flowcraft install [options]         角色向导或无人值守安装
flowcraft resume                    重启后继续第二阶段
flowcraft apply                     重应用配置
flowcraft status                    内核、TCP、qdisc 和重传状态
flowcraft diagnose                  状态及冲突诊断
flowcraft profile general|relay|landing
flowcraft kernel install|status|rollback
flowcraft network ipv4-priority on|off
flowcraft nic rps auto|off
flowcraft qdisc fq|fq_codel|fq_pie|cake
flowcraft security audit            只读检查 AEAD/Dirty Frag 风险面
flowcraft benchmark [--install]     测速；可从系统软件源安装客户端
flowcraft experimental max-throughput --yes
flowcraft rollback                  恢复安装前网络状态
flowcraft uninstall                 回滚并移除 Flowcraft
```

测速优先使用已有 `speedtest-cli`，其次使用 Ookla `speedtest`。两者都不存在时，菜单会询问是否从 Debian/Ubuntu 系统软件源安装 `speedtest-cli`；也可执行 `flowcraft benchmark --install`。最近一次测速结果保存在 `/var/lib/flowcraft/benchmark-result`。Flowcraft 不会删除或替换已有测速工具，也不会默认黑名单 `esp4`、`esp6`、`rxrpc`。安全审计只报告状态。

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
sudo flowcraft kernel status
# 通过 GRUB/VPS 控制台启动旧内核后
sudo flowcraft kernel rollback
```

Flowcraft 拒绝卸载正在运行的 Flowcraft 内核，也不会自动清除旧内核。

## 开发验证

```bash
bash -n bin/flowcraft lib/flowcraft/*.sh kernel/scripts/*.sh tests/*.sh
bash tests/self-test.sh
bash tests/install-smoke.sh
sudo bash tests/network-namespace.sh
```

CI 另外执行 ShellCheck、shfmt 和 network namespace 中的 qdisc 集成测试。真实内核安装仍必须在可恢复的一次性 Debian/Ubuntu VPS 上验收；容器测试不能证明 GRUB、云厂商引导链路或重启后的内核可用性。

## 来源与许可

Flowcraft 基于三个 MIT 项目的固定源码快照进行安全筛选整合。具体 commit、来源和适配范围见 [UPSTREAMS.lock](UPSTREAMS.lock) 与 [NOTICE](NOTICE)。Flowcraft 自身使用 [MIT License](LICENSE)。
