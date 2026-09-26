# Changelog

## 0.2.3 - 2026-09-26

- Added `flowcraft uninstall` and menu option 7, both delegating to the same
  fail-closed uninstaller used by `install.sh --uninstall`.
- Managed installations now retain a trusted installer helper so uninstall can
  require rollback before removing binaries, configuration, or recovery state.
- Reworked the README around completed capabilities, transaction boundaries,
  role-specific tuning, buffer calculations, qdisc takeover, and safe removal.
- Updated uninstall tests to exercise the real CLI dispatch without redefining
  functions after use, satisfying ShellCheck `SC2218` on GitHub Actions.

## 0.2.2 - 2026-09-26

- Added fail-closed takeover of kernel-default `fq` using a same-kernel,
  same-MTU disposable probe and complete parameter fingerprints.
- Added safe support for `mq` roots whose leaves are all kernel-default `fq`;
  unshaped policies retain `mq` and explicitly update every transmit-queue
  leaf without depending on the host's `net.core.default_qdisc`.
- `fq` and `mq` rollback now rebuild qdiscs before verifying the saved
  topology and parameters, preventing stale options such as `maxrate` from
  surviving a restore.
- Non-default `fq`, mixed `mq` leaves, extra qdiscs, probe failures, and
  topology drift remain rejected before takeover.

## 0.2.1 - 2026-09-26

- Added fail-closed takeover of standard `pfifo_fast` root qdiscs.
- Snapshots now preserve the fixed `bands` and complete `priomap` fingerprint;
  rollback recreates `pfifo_fast` and verifies the restored fingerprint.
- Non-standard `pfifo_fast` and all other unsupported unmanaged qdiscs remain
  rejected before network mutation.

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
