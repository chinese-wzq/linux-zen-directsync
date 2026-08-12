# linux-zen-directsync

Arch Linux package: Linux ZEN kernel with DirectSync patches for TSC synchronization on hardware without `IA32_TSC_ADJUST` MSR.

## What is DirectSync?

On such systems, the Linux kernel normally detects the absence of `TSC_ADJUST` and **marks TSC as unstable**, falling back to a slower clocksource (HPET, ACPI PM timer, etc.). This has a measurable impact on performance-sensitive workloads.

DirectSync works around this by writing directly to `MSR_IA32_TSC` (the raw TSC counter register) to synchronize TSC values across CPU cores. This allows the kernel to keep using the TSC clocksource even without `IA32_TSC_ADJUST`.

## When to use

Consider DirectSync if:
- Your CPU lacks the `IA32_TSC_ADJUST` MSR (check: `grep -q tsc_adjust /proc/cpuinfo || echo "no TSC_ADJUST"`)
- You are running in a VM / container environment where TSC_ADJUST is not exposed
- You see `clocksource: tsc: marking TSC unstable` in `dmesg`
- `cat /sys/devices/system/clocksource/clocksource0/current_clocksource` does not show `tsc`

**Do NOT use DirectSync if** your CPU already has `IA32_TSC_ADJUST` — it is unnecessary and adds no value.

## Caveats

DirectSync forces TSC to be used as the primary clocksource on hardware that was not designed to guarantee synchronized TSCs across cores.

## Usage

Append `tsc=directsync` to the kernel command line in your bootloader:

```
GRUB_CMDLINE_LINUX_DEFAULT="... tsc=directsync"
```

This enables:
- Direct TSC writes for synchronization
- Disables TSC watchdog (`no_tsc_watchdog = 1`) automatically

## Build

```bash
./update-PKGBUILD.sh
#or use ./update-PKGBUILD.sh --lld to use lld linker
makepkg -si
```

## Patches

| # | File | Description | Dependencies |
|---|------|-------------|-------------|
| 0001 | `x86-implement-tsc-directsync-for-systems-without-IA3.patch` | Core DirectSync implementation: write_tsc_adjustment(), 1000 retries, direct MSR_IA32_TSC writes | — |
| 0002 | `x86-touch-clocksource-watchdog-after-syncing-TSCs.patch` | Touch clocksource watchdog after SMP bring-up to prevent false positive | — |
| 0003 | `x86-save-restore-TSC-counter-value-during-sleep-wake.patch` | Save/restore TSC across suspend/resume in realmode wakeup | — |
| 0004 | `x86-only-restore-TSC-if-we-have-IA32_TSC_ADJUST-or-d.patch` | Only restore TSC on resume if TSC_ADJUST or directsync is available | 0003 |
| 0005 | `x86-don-t-check-for-random-warps-if-using-direct-syn.patch` | Skip random warp detection when using directsync | 0001 |
| 0006 | `x86-disable-tsc-watchdog-if-using-direct-sync.patch` | Automatically disable TSC watchdog when directsync is enabled | 0001 |

## Verify DirectSync is active

```bash
cat /proc/cmdline | tr ' ' '\n' | grep tsc       # Should show tsc=directsync
cat /sys/devices/system/clocksource/clocksource0/current_clocksource  # Should show tsc
dmesg | grep -i "direct.sync"                     # pr_debug messages (if enabled)
```

## Origin

Based on the official [linux-zen](https://gitlab.archlinux.org/archlinux/packaging/packages/linux-zen) Arch Linux package. The DirectSync patch set used here was sourced from [misotolar/linux-zen](https://github.com/misotolar/linux-zen); the patches themselves are authored by Steven Noonan &lt;steven@uplinklabs.net&gt;.
