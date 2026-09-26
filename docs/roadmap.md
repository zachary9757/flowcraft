# 重写路线

## M1：可恢复基础闭环

- `inspect`、`plan`、`apply`、`status`、`rollback`
- 单一 sysctl owner
- fq 或 HTB+fq 出口树
- 冲突拒绝、快照、锁、原子写入、运行态验证

## M2：观测与测量

- 无常驻进程的 `mon`
- 显式 `fit probe`
- policer 粗扫、细扫和最终复验
- 测量上下文指纹与过期策略

## M3：BBRv3 内核供应链

- x86_64/arm64 可复现构建
- 固定 patch、config、SHA256 和 provenance
- 安装后停止、人工重启、`resume` 验证
- 旧内核启动后的安全 rollback

## M4：平台覆盖

- Debian 12+、Ubuntu 24.04+
- PPP/PPPoE、virtio 多队列、64 KiB page
- Linux network namespace 集成测试
- 一次性 VPS 的 GRUB、重启和真实吞吐验收
