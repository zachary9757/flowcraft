# FlowCraft

FlowCraft 是面向 Linux VPS 的声明式网络调优工具。它不叠加安装多套网络脚本，
而是作为 `sysctl`、默认出口 root qdisc 和相关运行态的唯一配置所有者。

当前版本为 `0.2.1`，在可审计、幂等和可回滚的核心之上增加轻量交互与安装管理。

## 设计原则

- `inspect`、`plan`、`mon` 永远只读。
- `apply` 先检查冲突和回滚能力，再进行原子写入。
- 一个生成的 sysctl 文件、一个 systemd oneshot 服务、一个 qdisc owner。
- 不接管无法准确恢复的复杂 root qdisc。
- 不默认启用 RPS、ECN、极限缓冲、遥测或公共测速。
- 内核安装和流量测量是显式操作，不与基础调优隐式绑定。

## 命令

```text
flowcraft inspect [--json]
flowcraft plan
flowcraft apply
flowcraft status
flowcraft mon [--watch SECONDS]
flowcraft bbr status
flowcraft tc status|apply|off
flowcraft fit probe --peer HOST [--port 5201] [--duration 8]
flowcraft rollback
flowcraft version
```

`ftcp` 作为兼容入口，行为与 `flowcraft` 相同。不带参数运行 `flowcraft` 或 `ftcp`
会进入纯 Bash 交互面板；带参数时仍使用上述可审计的 CLI 命令。

## 快速开始

`v0.1.0` 是刻意重置版本号的不兼容架构重写，不复用 `v0.5.x` 的配置或快照格式。
旧版用户必须在替换程序前先使用原版本执行 `sudo ftcp rollback`，并备份后移走
`/etc/flowcraft` 与 `/var/lib/flowcraft`；新版检测到旧快照时会 fail-closed，拒绝修改网络。

全新 Linux VPS 可在 root shell 中使用一键安装。`install.sh` 检测到自己不是在完整
仓库中运行时，会通过 HTTPS 下载 `main` 分支源码，检查 Bash 4.4、iproute2、procps、
util-linux 等依赖，再安装到 `/usr/local`。安装本身**不会执行 `apply` 或修改网络运行态**：

```bash
curl -fsSL --proto '=https' https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh | bash
```

如需先审阅脚本，可下载后再运行：

```bash
curl -fLo install.sh https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh
less install.sh
sudo bash install.sh
```

已克隆仓库时仍可直接安装：

```bash
sudo ./install.sh
sudo flowcraft inspect
sudo flowcraft plan
sudo flowcraft
```

安装结束会询问是否立即进入面板。自动化环境可设置 `FLOWCRAFT_NO_PROMPT=1` 跳过询问。
两种安装方式本身都不会修改网络。默认配置位于 `/etc/flowcraft/config.conf`：

```text
ROLE=general
IFACE=auto
RTT_MS=100
PER_FLOW_MBPS=500
TOTAL_MBPS=0
QDISC_MODE=auto
```

角色：

- `general`：BBR 可用时使用 BBR，否则 Cubic；root fq，不限速。
- `relay`：缓冲按单流 BDP 计算；可使用 HTB 总出口加 fq 单流上限。
- `landing`：固定保守缓冲；有总出口值时使用 HTB aggregate shaping。

## 交互面板

面板是轻量展示与驱动层：它只原子更新白名单配置，并调用现有的 `plan`、`apply`、
`mon` 和 `rollback` 事务，不包含独立的 `sysctl -w` 或裸 `tc` 修改逻辑。

```text
FlowCraft 0.2.1
  BBR: active    qdisc: fq          Managed: yes
  Interface: eth0        Link: 1000 Mbps

[1] 通用调优（General / BBR + FQ + 动态缓冲）
[2] 中继优化（Relay / 吞吐缓冲 + 可选总限速）
[3] 落地机优化（Landing / 保守缓冲 + 可选总限速）
[4] 查看执行计划（Plan / Dry-Run）
[5] 实时连接与丢包监控（Monitor）
[6] 回滚到首次接管前状态（Rollback）
[0] 退出

请选择 [0-6]：
```

选取调优预设后，面板先展示完整计划并再次确认。`apply` 失败时底层事务负责恢复
网络状态，面板同时恢复原配置文件。

## 卸载

在仓库目录或下载后的安装脚本上运行：

```bash
sudo ./install.sh --uninstall
```

如果检测到托管配置或恢复快照，卸载器会要求先调用 `flowcraft rollback`；只有回滚
成功且恢复材料已清理后，才删除 systemd 单元、二进制、软链接、配置与状态目录。

## 支持边界

首版只管理一个默认出口接口的 egress，不管理 IFB ingress、多出口策略路由、
ECMP、隧道内层接口、防火墙、MSS clamp 或 eBPF 常驻监控。

详见 [架构](docs/architecture.md)、[冲突模型](docs/conflict-model.md)和
[实施路线](docs/roadmap.md)。

## 开发验证

```bash
bash tests/run.sh
```

真实 qdisc 和内核行为仍需在一次性 Linux VPS 上验收。
