# Rival Abadi Kernel — Infinix HOT 60 Pro+

A GKI build-and-gate pipeline for the Infinix HOT 60 Pro+ (MT6789, `android16-6.12`).

> **Status:** v1 (2026-09-30), v2 (2026-10-01), and v3 (2026-10-31) booted on hardware
> (including other MT6789 6.12 devices via the AnyKernel3 zip). **v4 (`20261101`)** — built
> with **Neutron Clang 24** (`06092026`, LLVM `f42c87ba`), fixing the **Neutron Clang 24
> `gendwarfksyms` DIE-cache bug** (`net_ns_type_operations` `0xe22fd8a9` so `cfg80211.ko` /
> Wi-Fi loads with **zero vendor waivers**), and updating **KernelSU-Next to 33452**
> (`v3.4.2-97-gcefb048b`, **uapi 6**) + **SusFS v2.3.0** (`f95c763`), alongside **BORE 7.0.0**,
> **Reflex 0.4.0**, **ntsync**, and the **self-tested AnyKernel3 installer** — is built,
> gated clean across all 505 device modules (`424 vendor + 81 system_dlkm`), and packaged.

## Variants & Features

| Variant | What | `uname -r` |
|---|---|---|
| **vanilla** | BORE 7.0.0 + Reflex 0.4.0 + ntsync + ADIOS 3.3.0 + Kcompressd 0.5 + le9uo 1.14 + `mt6789_balance` + BBR/fq/CAKE, no root | `6.12.38-RivalAbadi-vanilla` |
| **ksunext** | vanilla + KernelSU-Next **33452** (`v3.4.2-97-gcefb048b`, **uapi 6**) + SusFS **v2.3.0** (`f95c763`) | `6.12.38-RivalAbadi-ksunext` |

* **Scheduler:** **BORE 7.0.0** (Burst-Oriented Response Enhancer, `firelzrd`), KMI-packed
  into `task_struct` `ANDROID_KABI_RESERVE(3..7)` (one 8-byte member per union for
  `gendwarfksyms --stable`). Toggle live via `sysctl kernel.sched_bore=0`. Also includes
  built-in **sched_ext** (`CONFIG_SCHED_CLASS_EXT=y`).
* **CPUFreq:** **Reflex v0.4.0** (`firelzrd`, `latency_weight` default `300`) +
  **`mt6789_balance`** (boot boost, direct `freq_qos` touch floor, and deferrable
  screen-off cap gated on `lcd-backlight`).
* **Compat:** **ntsync** (`/dev/ntsync`, complete mainline driver with mutexes, events,
  wait-all/wait-any + mainline fixes `180a232ea780` and `61611481f7b5`) for Wine /
  Winlator.
* **Memory & Storage:** **MGLRU** (`CONFIG_LRU_GEN_ENABLED=y`), **Kcompressd 0.5**
  (`vm.kcompressd`, async zram swap-out), **le9uo 1.14** (`vm.workingset_protection=0`
  dormant by default), **ADIOS 3.3.0** + **BFQ** + **Kyber** + **mq-deadline** I/O
  schedulers.
* **Networking:** **TCP BBR** (default congestion control) + **fq** (default qdisc) +
  **CAKE** + Westwood / Vegas / H-TCP + TTL/HL netfilter targets.
* **Compiler:** **Neutron Clang 24** (`clang version 24.0.0git`, LLVM `f42c87ba`), with
  fallback support for AOSP `clang-r536225` (Clang 19.0.1).
* **ksunext Manager Note (uapi 6):** KernelSU-Next `33452` speaks **KSU uapi 6**
  (per-feature dynamic hook split). Because the `v3.4.2` release APK uses uapi 5, install
  the official CI manager build of `v3.4.2-97-gcefb048b` (versionCode `33452`):
  [manager.zip](https://nightly.link/KernelSU-Next/KernelSU-Next/actions/runs/41209311538/manager.zip).

## The point of this repo

Not "a kernel with tweaks". A **three-layer gate that refuses to ship a kernel that would
brick the device or break its modules**, built before any feature was added.

This phone runs a stock Google-built GKI (`6.12.38`, `KMI_GENERATION=5`). Its **424
vendor modules** (`235 vendor_boot + 189 vendor_dlkm`) and **81 `system_dlkm` modules**
are signed blobs we cannot rebuild, and they agree on `module_layout 0xe976b219` and
4,927 symbol CRCs. Get one wrong — or leave a GKI module export on
`CONFIG_MODULE_SIG_PROTECT`'s protected list — and modules fail to load (no Wi-Fi, no
Bluetooth, no touch, no display).

```
layer 1  symbol CRCs & module_layout against 424 vendor + 81 system_dlkm modules
layer 2  protected symbol exports table in vmlinux = 0 (no Google-signed module refused with -EACCES)
layer 3  4,927 vendor imports = 2,780 vmlinux + 2,147 siblings + 0 UNRESOLVED · 0 NOT permitted
```

All three layers were **proven able to fail** before being trusted — 11/11, 9/9, and 8/8
negative controls, none of which need a kernel to run:

```bash
./test/kmi-gate-selftest.sh
./test/protect-gate-selftest.sh
./test/import-gate-selftest.sh
```

## ⚠ Use the device's KMI generation, not "latest LTS"

`android16-6.12-lts` (6.12.93, `KMI_GENERATION=6`) is **KMI-broken on this device**:
9,907 of 24,071 CRCs mismatch — with every load-bearing config option identical
(`CFI_CLANG`, `LTO_NONE`, `MODVERSIONS`, `TRIM_UNUSED_KSYMS`, `SHADOW_CALL_STACK`,
`ARM64_MTE`, `KASAN_HW_TAGS`, `UBSAN`, `DEBUG_INFO_BTF`). So it is the generation,
not the configuration.

The device's own line — `android16-6.12-2025-09`, 6.12.38, generation **5** —
mismatches **zero**. GKI's ABI promise holds *within* a generation; a generation
bump is Google explicitly permitting a break. `sources.lock` records the pin and
the refutation together.

## Build & Package

```bash
./tools/fetch-toolchain.sh        # 5.3 GB: clang-r536225 + rust 1.82.0
./build.sh vanilla --stock        # pure ACK — measures the KMI alone
./build.sh vanilla                # + patches/series + config/vanilla_defconfig + brand
./build.sh ksunext                # vanilla + KernelSU-Next 33452 (uapi 6) + SusFS v2.3.0
./build.sh vanilla --gate-only    # re-gate without rebuilding
./package.sh vanilla              # AnyKernel3 zip + repacked boot.img (reads .build/staged-vanilla/)
./package.sh ksunext              # AnyKernel3 zip + repacked boot.img (reads .build/staged-ksunext/)
```

Beyond the KMI gate, `build.sh` asserts the release string in `kernel.release` and the
`Image` banner, every line of the config fragment in the built `.config`, and every
patch's config switch and probe symbol in `System.map` — a gate proves the ABI, not
the feature set. Upon `GATE: PASS`, `build.sh` stages the build outputs into
`.build/staged-<variant>/` so `package.sh` never collides on the shared `bazel-bin`.

`package.sh` also runs an automated **`busybox ash` AnyKernel3 execution self-test**
against a copy of the stock header-v4 kernel-only `boot.img` in a mock A/B recovery
environment on every run, asserting that `split_boot` + `flash_boot` exits 0 and writes
the new `RivalAbadi` kernel image cleanly.

`build.sh` refuses to build off a `common` that has drifted off `sources.lock`,
naming both shas — `repo sync` tracks the manifest *branch* and will silently
fast-forward past a pin.

## Do not enable LTO

`--lto=full` does not merely cost memory, it **fails to build**:
`Unable to find drivers/android/rust_binder.ko`, after 1310 s peaking at 13 GB RAM
and 24.9 GB swap. `ld.lld` completed; the Rust module is simply never produced while
the module list still demands it. Stock `LTO_NONE` is the only configuration that
finishes — and on 6.12 kCFI gives `CFI_CLANG` without LTO anyway.

`--lto` remains as a documented experiment knob, writing to a separate out-dir so it
cannot clobber a good build.

## Layout

```
build.sh                  build + 3-layer gate (+ branding, feature check, per-variant staging)
apply-mods.sh             applies patches/series to the pinned tree — strict, no fuzz
apply-ksunext-susfs.sh    KernelSU-Next (pershoot dev-susfs) + SusFS, ksunext only
patches/                  the ported MODIFICATIONS, one patch each, provenance in the header
config/                   vanilla_defconfig (all variants) + ksunext_defconfig
package.sh                AnyKernel3 zip + boot.img repack + ash execution self-test
sources.lock              pinned kernel ref, KSU/SusFS commits, toolchain versions, and why
device.conf               device facts: module_layout, vermagic, kernel format, brand, toolchain
lib/kmi_check.py          gate layer 1 — symbol CRCs vs the shipped vendor & system_dlkm modules
lib/protect_check.py      gate layer 2 — protected symbol exports table in vmlinux
lib/import_check.py       gate layer 3 — import accounting + permitted-import list
tools/fetch-prebuilt.sh   one toolchain version per subdirectory (5.3 GB, not 29 GB)
tools/harvest-kmi-ref.py  build the reference set from the device's own firmware
```

## Credits & Contributors

GKI and kleaf are Google's. BORE, Reflex, ADIOS, Kcompressd-Unofficial and le9uo
are firelzrd's (Kcompressd after Qun-Wei Lin, MediaTek); ntsync is Elizabeth Figura's
(CodeWeavers). KernelSU-Next, pershoot's `dev-susfs`, simonpunk's SusFS. Neutron Clang is
Neutron-Toolchains'. AnyKernel3 is osm0sis'.

**Contributors:**
* **Riza** (`riza220201`) — maintainer & project lead
* **Claude Opus** (Anthropic) — co-author (initial GKI 6.12 pipeline, 3-layer KMI gate, v1/v2 ports)
* **Gemini Argon** (Google DeepMind) — co-author (Neutron Clang 24 Kleaf integration & `gendwarfksyms` DIE-cache Wi-Fi fix, BORE 7.0.0 / Reflex 0.4.0 / KSU-Next 33452 uapi 6 updates, AnyKernel3 v4 GKI fix & self-test)
