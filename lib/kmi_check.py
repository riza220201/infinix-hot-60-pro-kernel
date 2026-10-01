#!/usr/bin/env python3
"""Cross-check a built kernel's symbol CRCs against this device's stock modules.

Usage: kmi_check.py <vmlinux.symvers> <kmi_ref_tree>

<kmi_ref_tree> is a DIRECTORY TREE, one subdirectory per shipped module set
(here: vendor_dlkm/ and vendor_boot/). Walking a tree rather than one flat
directory is deliberate: this device ships two independent module sets and BOTH
must load, so the report is per-subset and a stray is named by its tree-relative
path — a flat reference directory hides which set a stray came from.

Exit codes are distinct on purpose:
    0  CLEAN      every stock module's CRCs are satisfied by this kernel
    1  BROKEN     at least one CRC mismatch -> modules would be rejected at load
    2  VACUOUS    nothing was actually checked (wrong path, empty tree)
    3  WRONG SET  the reference set is not the one this device ships

🔴 THE REFERENCE SET IS AN INPUT, AND AN INPUT CAN BE WRONG.
This gate answers "will my kernel load THESE modules". It cannot notice that
"these" stopped being the modules the device actually ships. On the sibling itel
RS4 project (2026-09-03) exactly that happened: the reference directory still
held a module set that had been replaced the day before, so a healthy-looking
"ok=198 bad=0" was measured against modules nobody ships. Both sets passed, so
there was no symptom — which is what makes it worth guarding.

So assert the PROVENANCE of the reference set too. In device.conf (exported, so
this subprocess sees it):

    export KMI_EXPECT_VERMAGIC="6.12.38-android16-5-gcc51d883045d-4k"
    export KMI_VERMAGIC_EXCEPTIONS=""      # modules we compile ourselves

Every reference module must carry that vermagic prefix, except the named files.
Anything else is a wrong reference set and exits 3. Leave KMI_EXPECT_VERMAGIC
unset to keep CRC-only behaviour.

🪤 6.12 note: modules carry BOTH the classic 64-byte `__versions` table and the
extended `__version_ext_crcs`/`__version_ext_names` pair. On this device's set
the two agree everywhere and neither holds a symbol the other lacks, but we read
and merge both anyway — a symbol name of 56 characters or more can ONLY be
represented in the extended sections, so parsing the classic table alone would
silently skip exactly the symbols most likely to be new.
"""
import sys, struct, glob, os, collections
from elftools.elf.elffile import ELFFile

if len(sys.argv) != 3:
    sys.exit("usage: kmi_check.py <vmlinux.symvers> <kmi_ref_tree>")
symvers_path, ref_tree = sys.argv[1], sys.argv[2]

sv = {}
with open(symvers_path) as f:
    for ln in f:
        p = ln.split('\t')
        if len(p) >= 2:
            sv[p[1].strip()] = int(p[0], 16) & 0xffffffff


def read_module(path):
    """-> (vermagic, {symbol: crc}) merging classic and extended modversions."""
    ef = ELFFile(open(path, 'rb'))
    vermagic = ''
    mi = ef.get_section_by_name('.modinfo')
    if mi:
        for field in mi.data().split(b'\x00'):
            if field.startswith(b'vermagic='):
                vermagic = field[len(b'vermagic='):].decode('latin1')
    refs = {}
    sec = ef.get_section_by_name('__versions')
    if sec:
        d = sec.data()
        for i in range(0, len(d), 64):          # modversion_info = 8B crc + 56B name
            c = d[i:i + 64]
            if len(c) < 64:
                break
            nm = c[8:].split(b'\x00')[0].decode('latin1')
            if nm:
                refs[nm] = struct.unpack('<Q', c[:8])[0] & 0xffffffff
    ec = ef.get_section_by_name('__version_ext_crcs')
    en = ef.get_section_by_name('__version_ext_names')
    if ec and en:
        d = ec.data()
        crcs = [struct.unpack('<I', d[i:i + 4])[0] for i in range(0, len(d), 4)]
        names = [n.decode('latin1') for n in en.data().split(b'\x00') if n]
        refs.update(dict(zip(names, crcs)))
    return vermagic, refs


kos = sorted(glob.glob(os.path.join(ref_tree, '**', '*.ko'), recursive=True))
subsets = collections.Counter()
vermagics = collections.defaultdict(list)
tot = match = mism = missing = ml_ok = ml_bad = 0
examples = []
per_subset_bad = collections.Counter()

# KMI_KNOWN_BAD_MODULES: basenames whose failures are DECLARED (reported, not
# counted) — e.g. system_dlkm's rust_binder.ko, whose Rust-crate imports are not
# KMI-stable. Unset = every module counts, exactly as before.
known_bad = set(os.environ.get('KMI_KNOWN_BAD_MODULES', '').replace(',', ' ').split())
known_bad_hits = collections.Counter()
for ko in kos:
    rel = os.path.relpath(ko, ref_tree)
    subset = rel.split(os.sep)[0] if os.sep in rel else '(root)'
    subsets[subset] += 1
    vermagic, refs = read_module(ko)
    vermagics[vermagic.split(' ')[0]].append(rel)
    for nm, crc in refs.items():
        tot += 1
        if nm not in sv:
            missing += 1                        # provided by a sibling module, resolved at load
            continue
        if sv[nm] == crc:
            match += 1
            if nm == 'module_layout':
                ml_ok += 1
        elif os.path.basename(ko) in known_bad:
            known_bad_hits[os.path.basename(ko)] += 1
        else:
            mism += 1
            per_subset_bad[subset] += 1
            if nm == 'module_layout':
                ml_bad += 1
            elif len(examples) < 15:
                examples.append((rel, nm, hex(crc), hex(sv[nm])))

print(f"reference tree  : {ref_tree}")
print("module sets     : " + ("  ".join(f"{n}x {s}" for s, n in sorted(subsets.items()))
                              or "(none)") + f"  [total {len(kos)}]")
print("vermagic        : " + ("  ".join(f"{len(v)}x {k or '(none)'}"
                                        for k, v in sorted(vermagics.items(),
                                                           key=lambda kv: -len(kv[1])))
                              or "(no modules)"))
print(f"symbol refs     : {tot}")
print(f"  MATCH         : {match}")
print(f"  CRC-MISMATCH  : {mism}")
print(f"  not-in-vmlinux: {missing}  (inter-vendor, resolved module-to-module at load)")
print(f"module_layout   : ok={ml_ok} bad={ml_bad}")
if per_subset_bad:
    print("mismatches by set: " + "  ".join(f"{s}={n}" for s, n in sorted(per_subset_bad.items())))
for m in sorted(known_bad):
    if known_bad_hits[m]:
        print(f"known-bad       : {m} — {known_bad_hits[m]} CRC mismatch(es), DECLARED, not counted")
    elif m in {os.path.basename(k) for k in kos}:
        print(f"known-bad       : {m} — declared, no CRC mismatch in this layer (still needed by another?)")
    else:
        print(f"known-bad       : {m} — declared but not in this reference tree")
if examples:
    print("sample mismatches (module, symbol, module-wants, our-vmlinux):")
    for e in examples:
        print("   ", e)

# ── Vacuous-pass guard ────────────────────────────────────────────────────────
if len(kos) == 0 or ml_ok + ml_bad == 0:
    print(f"RESULT: checked {len(kos)} modules / {ml_ok + ml_bad} module_layout refs — "
          f"nothing to verify (wrong reference tree?). NOT a pass.")
    sys.exit(2)

# ── Provenance of the reference set (opt-in) ─────────────────────────────────
expect = os.environ.get('KMI_EXPECT_VERMAGIC', '').strip()
if expect:
    allowed = set(os.environ.get('KMI_VERMAGIC_EXCEPTIONS', '').replace(',', ' ').split())
    strays = sorted(rel for vm, rels in vermagics.items() for rel in rels
                    if not vm.startswith(expect) and os.path.basename(rel) not in allowed)
    if strays:
        print(f"\nRESULT: {len(strays)} reference module(s) do NOT carry the expected "
              f"vermagic '{expect}' and are not declared exceptions.")
        print("        This is a WRONG REFERENCE SET, not a bad kernel — the CRC result")
        print("        above is therefore about modules this device does not ship.")
        for rel in strays[:10]:
            print(f"          {rel}")
        if len(strays) > 10:
            print(f"          … and {len(strays) - 10} more")
        sys.exit(3)
    present = {os.path.basename(r) for v in vermagics.values() for r in v}
    excused = sorted(allowed & present)
    print(f"provenance      : ok — {len(kos) - len(excused)} carry '{expect}'"
          + (f"; {len(excused)} declared exception(s): {', '.join(excused)}" if excused else ""))

if mism == 0:
    print("RESULT: CLEAN — every stock module loads natively (KMI-safe to ship)")
    sys.exit(0)
print(f"RESULT: {mism} CRC mismatches — KMI BROKEN, do NOT ship")
sys.exit(1)
