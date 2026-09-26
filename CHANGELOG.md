# Changelog

## 0.1.0 - 2026-09-26

- Intentionally reset the version after the architecture rewrite; state and
  configuration from 0.5.x require rollback and removal before installation.
- Rebuilt the project around a single-owner declarative control model.
- Added read-only inspect, plan, status, BBR status, and monitoring commands.
- Added conservative sysctl rendering, fq/HTB/CAKE egress management, snapshots,
  rollback, conflict refusal, and runtime verification.
- Added explicit, non-applying iperf3 probe support.
