# 配置所有权与冲突模型

## 拒绝接管

以下任一情况会使 `apply` 在写入前失败：

- 其他 sysctl 文件设置 FlowCraft 管理的关键 TCP 参数；
- 默认出口存在 CAKE、HTB、TBF、netem 等无法无损序列化的复杂 root qdisc；
- 首次快照记录的接口与当前目标接口不同；
- 默认路由是多路径或无法唯一确定出口接口。

## 可接管队列

FlowCraft 允许从 `noqueue`、没有 root qdisc，或具有标准固定指纹的
`pfifo_fast` 状态接管。`pfifo_fast` 快照记录 `bands` 与完整 16 项 `priomap`，
回滚时用内核支持的裸 qdisc 重建并逐项验证。非标准 `pfifo_fast`、已有 `fq`
（可能带 `maxrate`）以及 `mq`（可能带自定义叶子）仍会被拒绝。

## 幂等性

- 配置通过白名单解析，不使用 `source` 或 `eval`。
- 生成文件先写临时文件，再原子替换。
- 快照只在首次接管时创建。
- 重复 `apply` 从声明式配置重建相同状态，不追加配置。
- 运行态值在写入后重新读取验证。

## 发布边界闭环

`0.1.0` 将以下 13 项作为发布门禁：

1. 唯一默认路由检查并拒绝 ECMP。
2. 扫描并拒绝其他 sysctl owner。
3. 首次只接管 `none` 或 `noqueue` root qdisc。
4. 配置仅按白名单解析，异常输入 fail-closed。
5. 所有持久状态写入和网络变更共用全局 `flock`。
6. 生成文件和状态文件使用同目录临时文件原子替换。
7. 首次接管快照在复用前验证格式与完整性。
8. qdisc 快照绑定接管时的出口接口。
9. 每次应用建立独立事务基线，失败恢复本次变更前状态。
10. sysctl 应用后逐键读取运行态验证。
11. qdisc 应用后验证类型、层级、速率和模式参数。
12. `tc off` 同样执行 apply、verify、rollback 事务。
13. 显式 rollback 在停止服务或修改网络前验证全部恢复材料。

`0.2.1` 在不放宽其他 qdisc 的前提下，将标准 `pfifo_fast` 纳入同一套
snapshot、verify、rollback 门禁。
