# FlowCraft

FlowCraft 是面向 Linux VPS 的声明式网络调优工具。它不叠加安装多套网络脚本，
而是作为 `sysctl`、默认出口 root qdisc 和相关运行态的唯一配置所有者。

当前为从零重写的 `0.1.0` 基础版本，优先实现可审计、幂等和可回滚的最小闭环。

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

`ftcp` 作为兼容入口，行为与 `flowcraft` 相同。

## 快速开始

`v0.1.0` 是刻意重置版本号的不兼容架构重写，不复用 `v0.5.x` 的配置或快照格式。
旧版用户必须在替换程序前先使用原版本执行 `sudo ftcp rollback`，并备份后移走
`/etc/flowcraft` 与 `/var/lib/flowcraft`；新版检测到旧快照时会 fail-closed，拒绝修改网络。

```bash
sudo ./install.sh
sudo flowcraft inspect
sudo flowcraft plan
sudo flowcraft apply
```

安装本身不会修改网络。默认配置位于 `/etc/flowcraft/config.conf`：

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
