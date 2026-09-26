# FlowCraft

FlowCraft 是面向 Linux VPS 的声明式网络调优与出口队列管理工具。它把
`sysctl`、默认出口 qdisc 和恢复快照收敛到一个事务中，作为系统的 **Single
Network Owner（单一网络配置所有者）**，避免多套脚本相互覆盖、重复调参或留下
无法恢复的运行态。

当前版本：`0.2.3`。

## 已完成功能

| 能力 | 已实现行为 |
| --- | --- |
| 系统检查 | `inspect` 只读识别内核、默认路由、出口接口、拥塞算法、qdisc、BBR 能力和 sysctl owner 冲突 |
| 变更预览 | `plan` 渲染将要写入的 sysctl 和将要执行的 `tc` 命令，不修改系统 |
| 事务应用 | `apply` 在全局 `flock` 内完成系统预检、首次快照、写入、运行态验证；任一步失败自动恢复本次变更 |
| 状态与漂移 | `status` 展示角色、接口、拥塞算法、root qdisc，并验证托管 sysctl 是否漂移 |
| qdisc 管理 | 支持 `fq`、HTB + `fq`，以及显式配置 CAKE；支持标准 `mq` 多队列网卡的逐队列 `fq` |
| 三类预设 | `general`、`relay`、`landing` 分别覆盖通用主机、中继转发和落地机 |
| 只读监控 | `mon` 前台读取连接、TCP 统计和 qdisc 统计，不安装常驻采集进程 |
| 主动测量 | `fit probe` 显式调用指定的 iperf3 peer，记录测量结果但绝不自动修改配置 |
| 回滚 | `rollback` 校验首次接管快照并恢复原 sysctl 与 qdisc |
| 交互面板 | 无参数运行 `flowcraft` 或 `ftcp`，使用纯 Bash 菜单驱动底层命令 |
| 安装与卸载 | 支持在线/本地安装、兼容命令 `ftcp`，以及面板或 CLI 安全卸载 |

FlowCraft 不安装内核、不自动重启，也不会在 `inspect`、`plan`、`status`、`mon`
或 `fit probe` 中隐式改写网络。

## 工作原理

`apply` 的事务边界如下：

```text
加载并严格校验配置
  -> 获取全局 flock
  -> 拒绝 ECMP、多默认出口和其他 sysctl owner
  -> 验证现有 qdisc 可准确恢复
  -> 保存首次接管快照和本次事务基线
  -> 应用 sysctl 与出口 qdisc
  -> 对照声明验证内核运行态
  -> 写入 managed.state

任何应用或验证失败
  -> 恢复本次事务前的 sysctl 与 qdisc
  -> 保留必要恢复材料并返回失败
```

持久化边界只有以下几处：

- `/etc/flowcraft/config.conf`：用户声明的白名单配置。
- `/etc/sysctl.d/90-flowcraft.conf`：FlowCraft 唯一生成的 sysctl 文件。
- `/var/lib/flowcraft/`：带完整性校验的首次快照与托管状态。
- `/etc/systemd/system/flowcraft.service`：开机恢复声明状态的 oneshot 单元。

配置解析采用 fail-closed 策略：未知键、重复/非法状态、越界数值、损坏快照、其他
sysctl owner 或无法证明可恢复的 qdisc 都会阻止应用。

## 安装

### 在线一键安装

在 root shell 中运行：

```bash
curl -fsSL --proto '=https' https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh | bash
```

如需先审阅安装器：

```bash
curl -fLo /tmp/flowcraft-install.sh https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh
less /tmp/flowcraft-install.sh
sudo bash /tmp/flowcraft-install.sh
rm -f /tmp/flowcraft-install.sh
```

安装器要求 Linux、root、Bash 4.4+、iproute2、procps、util-linux 和 systemd。
它把程序安装到 `/usr/local`，创建 `flowcraft` 与 `ftcp` 入口，但**安装过程不会执行
`apply` 或修改网络运行态**。安装结束后可选择进入交互面板；自动化环境设置
`FLOWCRAFT_NO_PROMPT=1` 可关闭询问。

### 本地仓库安装

```bash
git clone https://github.com/zachary9757/flowcraft.git
cd flowcraft
sudo ./install.sh
```

安装后建议先只读检查和预览：

```bash
sudo flowcraft inspect
sudo flowcraft plan
sudo flowcraft
```

## 交互面板

面板只负责展示、确认和驱动。它通过原子方式更新白名单配置，然后调用已有的
`plan`、`apply`、`mon`、`rollback` 或 `uninstall`；面板本身不包含 `sysctl -w`
或裸 `tc` 写入逻辑。

```text
FlowCraft 0.2.3
  BBR: active    qdisc: fq          Managed: yes
  Interface: eth0        Link: 1000 Mbps

[1] 通用调优（General / BBR + FQ + 动态缓冲）
[2] 中继优化（Relay / 吞吐缓冲 + 可选总限速）
[3] 落地机优化（Landing / 保守缓冲 + 可选总限速）
[4] 查看执行计划（Plan / Dry-Run）
[5] 实时连接与丢包监控（Monitor）
[6] 回滚到首次接管前状态（Rollback）
[7] 安全回滚并完全卸载（Uninstall）
[0] 退出

请选择 [0-7]：
```

选择 1/2/3 后，面板先保存对应角色和带宽参数，再打印完整计划并要求二次确认。
如果 `apply` 失败，底层事务恢复网络，面板同时恢复应用前的配置文件。

## 调优逻辑

默认声明位于 `/etc/flowcraft/config.conf`：

```text
ROLE=general
IFACE=auto
RTT_MS=100
PER_FLOW_MBPS=500
TOTAL_MBPS=0
QDISC_MODE=auto
```

参数含义：

- `IFACE=auto`：只接受唯一默认出口；多默认路由或 ECMP 会被拒绝。
- `RTT_MS`：用于估算通用/中继角色的单流带宽时延积。
- `PER_FLOW_MBPS`：缓冲估算速率；在 `relay` 中同时是 `fq maxrate` 的单流上限。
- `TOTAL_MBPS=0`：不设置 HTB 总出口限速；非零时 `auto` 使用 HTB。
- `QDISC_MODE=auto`：总带宽为 0 时选择 `fq`，非零时选择 HTB + `fq`。

### 角色差异

| 角色 | 缓冲策略 | `TOTAL_MBPS=0` | `TOTAL_MBPS>0` |
| --- | --- | --- | --- |
| `general` | 按 `PER_FLOW_MBPS × RTT_MS` 估算动态缓冲 | root/逐队列 `fq`，不设速率 | HTB 限制总出口，叶子 `fq` |
| `relay` | 按单流 BDP 估算动态缓冲 | `fq maxrate PER_FLOW_MBPS`，限制单流但不限制聚合带宽 | HTB 限制总出口，叶子 `fq maxrate` 限制单流 |
| `landing` | 低内存主机 16 MiB，否则 32 MiB，再受内存上限约束 | root/逐队列 `fq`，不设速率 | HTB 限制总出口，叶子 `fq` |

通用/中继缓冲目标约为：

```text
PER_FLOW_MBPS × RTT_MS × 125 × 2 + 2 MiB
```

结果最低 4 MiB，并受内存相关上限约束：约为物理内存的 1/32，最低 4 MiB、最高
256 MiB。Landing 使用保守固定目标后再应用同一内存上限。

FlowCraft 根据内核能力优先选择 BBR，其次 Cubic；它只选择已存在的拥塞控制算法，
不会安装或替换内核。生成的 sysctl 还包括 TCP 收发缓冲、窗口缩放、MTU probing、
TCP Fast Open、`somaxconn` 和 `netdev_max_backlog`。实际值始终可在 `flowcraft plan`
中先行审阅。

### qdisc 接管规则

首次应用只接管能够完整识别并准确恢复的状态：

- `none` / `noqueue`；
- 标准参数的 `pfifo_fast`；
- 经同内核、同 MTU 临时 dummy 接口指纹验证的默认 `fq`；
- root `mq` 且所有 TX 队列均为同一默认 `fq`。

自定义 `fq`、CAKE、HTB、第三方整形层、无法识别的 `mq` 叶子以及其他复杂 qdisc
都会 fail-closed。对于标准 `mq`，FlowCraft 保留多队列拓扑并逐 TX 队列管理 `fq`。

## 命令参考

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
flowcraft uninstall
flowcraft version
```

`ftcp` 是兼容入口，行为与 `flowcraft` 相同。

推荐操作顺序：

```bash
sudo flowcraft inspect
sudo flowcraft plan
sudo flowcraft apply
sudo flowcraft status
```

## 卸载

当前版本可直接使用 CLI 或交互面板选项 7：

```bash
sudo flowcraft uninstall
```

如果仍处于托管状态，卸载器会要求确认并先执行 `flowcraft rollback`。只有回滚成功且
托管材料已经清理，才会删除 systemd 单元、命令入口、程序库、配置和状态目录。

尚未提供 `flowcraft uninstall` 的旧版本，请使用最新版安装器执行兼容卸载：

```bash
curl -fsSL --proto '=https' https://raw.githubusercontent.com/zachary9757/flowcraft/main/install.sh -o /tmp/flowcraft-install.sh
sudo bash /tmp/flowcraft-install.sh --uninstall
rm -f /tmp/flowcraft-install.sh
```

不要在托管状态下直接 `rm -rf` 安装目录；那会丢失回滚程序或恢复快照。

## 支持边界

FlowCraft 当前只管理一个默认出口接口的 egress。以下内容不在自动管理范围内：

- IFB ingress、入站 policing；
- 多出口策略路由、ECMP；
- 隧道内层接口、容器网络；
- 防火墙、NAT、MSS clamp；
- RPS/XPS、eBPF 或常驻遥测服务；
- 内核安装、内核升级和自动重启；
- 未显式指定 peer 的公共测速。

详见 [架构](docs/architecture.md)、[冲突模型](docs/conflict-model.md)和
[实施路线](docs/roadmap.md)。

## 开发验证

```bash
bash tests/run.sh
```

涉及真实内核 qdisc、systemd 和路由的行为仍应在一次性 Linux VPS 上做最终验收。
