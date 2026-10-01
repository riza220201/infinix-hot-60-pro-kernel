# Rival Abadi Kernel — Infinix HOT 60 Pro+

A GKI build-and-gate pipeline for the Infinix HOT 60 Pro+ (MT6789, android16-6.12).

> **Status:** v1 (2026-09-30) shipped; its ksunext kernel **boots** on a volunteer
> tester's phone. v2 (2026-10-01) — clean release string `6.12.38-RivalAbadi-<variant>`
> and seven source ports (BORE, ntsync, Reflex, ADIOS, Kcompressd, le9uo,
> mt6789_balance) plus BBR — is built, gated clean and packaged, but **not yet booted**.

## The point of this repo

Not "a kernel with tweaks". A **gate that refuses to ship a kernel that would brick
the device**, built before any feature was added.

This phone runs a stock Google-built GKI. Its 424 vendor modules
(235 `vendor_boot` + 189 `vendor_dlkm`) are signed blobs we cannot rebuild, and they
agree on `module_layout 0xe976b219` and 4,927 symbol CRCs. Get one wrong and the
module does not load — no Wi-Fi, no touch, no display.

```
layer 1  24,071 symbol refs · CRC-MISMATCH 0 · module_layout ok=424 bad=0
layer 3  4,927 imports = 2,780 vmlinux + 2,147 siblings + 0 UNRESOLVED
         permitted list 9,615 symbols · NOT permitted 0
```

Both layers were **proven able to fail** before being trusted — 11/11 and 8/8
negative controls, none of which need a kernel to run:

```bash
./test/kmi-gate-selftest.sh
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

## Build

```bash
./tools/fetch-toolchain.sh        # 5.3 GB: clang-r536225 + rust 1.82.0
./build.sh vanilla --stock        # pure ACK — measures the KMI alone
./build.sh vanilla                # + patches/series + config/vanilla_defconfig + brand
./build.sh ksunext                # vanilla + KernelSU-Next + SusFS
./build.sh vanilla --gate-only    # re-gate without rebuilding
./package.sh vanilla              # AnyKernel3 zip + repacked boot.img — right after
                                  #   building THAT variant (bazel-bin is shared)
```

Beyond the KMI gate, `build.sh` asserts the release string in `kernel.release` and the
`Image` banner, every line of the config fragment in the built `.config`, and every
patch's config switch and probe symbol in `System.map` — a gate proves the ABI, not
the feature set.

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
build.sh              build + gate (+ branding, feature check)
apply-mods.sh         applies patches/series to the pinned tree — strict, no fuzz
apply-ksunext-susfs.sh  KernelSU-Next (pershoot dev-susfs) + SusFS, ksunext only
patches/              the ported MODIFICATIONS, one patch each, provenance in the header
config/               vanilla_defconfig (all variants) + ksunext_defconfig
package.sh            AnyKernel3 zip + boot.img repack (refuses unless gates are CLEAN)
sources.lock          pinned kernel ref, toolchain versions, and why
device.conf           device facts: module_layout, vermagic, kernel format, brand
lib/kmi_check.py      gate layer 1 — symbol CRCs vs the shipped modules
lib/import_check.py   gate layer 3 — import accounting + permitted-import list
tools/fetch-prebuilt.sh   one toolchain version per subdirectory (5.3 GB, not 29 GB)
tools/harvest-kmi-ref.py  build the reference set from the device's own firmware
release-v2.sh         creates the v2 GitHub release as a DRAFT (tag + checksums checked)
```

## Credits

GKI and kleaf are Google's. BORE, Reflex, ADIOS, Kcompressd-Unofficial and le9uo
are firelzrd's (Kcompressd after Qun-Wei Lin, MediaTek); ntsync is Elizabeth Figura's
(CodeWeavers). KernelSU-Next, pershoot's `dev-susfs`, simonpunk's SusFS. AnyKernel3 is
osm0sis'. The gate, the pins and the
refutations are this repo's.
