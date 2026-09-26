# FlowCraft 架构

## 控制模型

```text
discover -> validate -> render -> plan -> snapshot -> apply -> verify
                                                  \-> rollback
```

用户配置只描述意图，派生的 sysctl 和 tc 命令每次重新生成。任何模块都不得绕过
统一 apply 路径直接持久化网络状态。

## 模块

| 模块 | 职责 | 写权限 |
| --- | --- | --- |
| discover | 系统、路由、内核、接口和冲突发现 | 无 |
| config | 白名单解析声明式配置 | 配置文件 |
| sysctl | 计算、生成、应用和验证 TCP 参数 | 单一 sysctl 文件 |
| tc | 构造并验证唯一出口 qdisc 树 | 选定接口 root qdisc |
| bbr | BBR 能力和运行状态 | 首版只读 |
| fit | 显式 iperf3 测量 | 只写测量结果 |
| mon | 聚合运行态观测 | 无 |
| rollback | 恢复首次接管前快照 | 已拥有资源 |

## 状态路径

```text
/etc/flowcraft/config.conf
/etc/sysctl.d/90-flowcraft.conf
/etc/systemd/system/flowcraft.service
/var/lib/flowcraft/sysctl.snapshot
/var/lib/flowcraft/qdisc.snapshot
/var/lib/flowcraft/fit-result
/run/lock/flowcraft.lock
```

## 角色策略

`general` 不设置人为带宽上限。`relay` 的单流策略与整机总出口分开；总出口由
HTB 管理，fq 作为叶子负责逐流 pacing。`landing` 不复用 relay 的远距离 BDP
模型，使用固定的保守缓冲上限，并只把已知物理出口值用于 aggregate shaping。
