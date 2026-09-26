# Changelog

## 0.2.0 - 2026-09-26

- Added a dependency-free Bash menu for status, role presets, planning,
  monitoring, transactional apply, and rollback.
- Added validated, atomic preset configuration updates with restoration after
  cancelled or failed applies.
- Extended `install.sh` for local and one-line online installation, runtime
  dependency checks, optional menu launch, and fail-closed uninstallation.
- Hardened apply so snapshot failures explicitly stop before any network
  mutation, including when invoked from conditional menu control flow.
- Added menu, configuration persistence, and snapshot failure regression tests.

## 0.1.0 - 2026-09-26

- Intentionally reset the version after the architecture rewrite; state and
  configuration from 0.5.x require rollback and removal before installation.
- Rebuilt the project around a single-owner declarative control model.
- Added read-only inspect, plan, status, BBR status, and monitoring commands.
- Added conservative sysctl rendering, fq/HTB/CAKE egress management, snapshots,
  rollback, conflict refusal, and runtime verification.
- Added explicit, non-applying iperf3 probe support.
