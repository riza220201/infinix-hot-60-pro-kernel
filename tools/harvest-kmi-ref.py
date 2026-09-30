#!/usr/bin/env python3
"""Read this device's exported-ABI reference straight off its SHIPPED modules.

Usage: harvest-kmi-ref.py <kmi_ref_tree> [out.symvers]

Walks every stock `.ko` under the tree, merges the classic `__versions` table
with the extended `__version_ext_crcs`/`__version_ext_names` pair, and emits the
union as a `Module.symvers`-format file (`<crc>\tname\tvmlinux\tEXPORT_SYMBOL`).

Why this and not just `module_layout`: `module_layout` is ONE symbol. The set of
symbols the device's modules actually import is thousands, and every one of them
must match or that module is rejected at load. Harvesting them from the binaries
gives a self-consistent picture of the kernel ABI this device demands, written by
the people who shipped it, with no build of our own involved.

It also serves as the gate's POSITIVE CONTROL: feed the harvested file to
kmi_check.py as if it were a built kernel's symvers and the answer must be a
perfect score. A gate that has never been shown to pass on a known-good input,
and fail on a known-bad one, is not yet a gate.

⚠ What this CANNOT do: it only recovers symbols some stock module happens to
import. Symbols the kernel exports but nobody uses are unrecoverable here — a
negative grep is only as good as its scope.
"""
import sys, struct, glob, os, collections

from elftools.elf.elffile import ELFFile

if not 2 <= len(sys.argv) <= 3:
    sys.exit("usage: harvest-kmi-ref.py <kmi_ref_tree> [out.symvers]")
ref_tree = sys.argv[1]
out_path = sys.argv[2] if len(sys.argv) == 3 else None


def read_module(path):
    ef = ELFFile(open(path, 'rb'))
    vermagic = ''
    mi = ef.get_section_by_name('.modinfo')
    if mi:
        for field in mi.data().split(b'\x00'):
            if field.startswith(b'vermagic='):
                vermagic = field[len(b'vermagic='):].decode('latin1')
    classic, ext = {}, {}
    sec = ef.get_section_by_name('__versions')
    if sec:
        d = sec.data()
        for i in range(0, len(d), 64):
            c = d[i:i + 64]
            if len(c) < 64:
                break
            nm = c[8:].split(b'\x00')[0].decode('latin1')
            if nm:
                classic[nm] = struct.unpack('<Q', c[:8])[0] & 0xffffffff
    ec = ef.get_section_by_name('__version_ext_crcs')
    en = ef.get_section_by_name('__version_ext_names')
    if ec and en:
        d = ec.data()
        crcs = [struct.unpack('<I', d[i:i + 4])[0] for i in range(0, len(d), 4)]
        names = [n.decode('latin1') for n in en.data().split(b'\x00') if n]
        ext = dict(zip(names, crcs))
    return vermagic, classic, ext


kos = sorted(glob.glob(os.path.join(ref_tree, '**', '*.ko'), recursive=True))
if not kos:
    sys.exit(f"no .ko under {ref_tree} — nothing to harvest")

syms, owner = {}, {}
conflicts = []
vermagics = collections.Counter()
subsets = collections.Counter()
mls = collections.Counter()
ext_only = set()
classic_only = set()
refs = 0

for ko in kos:
    rel = os.path.relpath(ko, ref_tree)
    subsets[rel.split(os.sep)[0] if os.sep in rel else '(root)'] += 1
    vermagic, classic, ext = read_module(ko)
    vermagics[vermagic] += 1
    ext_only |= set(ext) - set(classic)
    classic_only |= set(classic) - set(ext)
    merged = dict(classic)
    merged.update(ext)
    refs += len(merged)
    if 'module_layout' in merged:
        mls[hex(merged['module_layout'])] += 1
    for nm, crc in merged.items():
        if nm in syms and syms[nm] != crc:
            conflicts.append((nm, rel, hex(crc), owner[nm], hex(syms[nm])))
        syms[nm] = crc
        owner[nm] = rel

print(f"reference tree   : {ref_tree}")
print("module sets      : " + "  ".join(f"{n}x {s}" for s, n in sorted(subsets.items()))
      + f"  [total {len(kos)}]")
for vm, n in vermagics.most_common():
    print(f"vermagic         : {n}x {vm}")
for ml, n in mls.most_common():
    print(f"module_layout    : {n}x {ml}")
print(f"symbol refs      : {refs}")
print(f"distinct symbols : {len(syms)}")
print(f"CRC conflicts    : {len(conflicts)}")
for c in conflicts[:10]:
    print("   ", c)
print(f"extended-only    : {len(ext_only)} symbol name(s) present ONLY in __version_ext_*")
print(f"classic-only     : {len(classic_only)} symbol name(s) present ONLY in __versions")

if len(vermagics) != 1 or len(mls) != 1:
    print("\n⚠ the reference set is NOT self-consistent — more than one vermagic or "
          "module_layout. Sort that out before trusting any number above.")

if out_path:
    with open(out_path, 'w') as f:
        for nm in sorted(syms):
            f.write("0x%08x\t%s\tvmlinux\tEXPORT_SYMBOL\n" % (syms[nm], nm))
    print(f"wrote            : {out_path}  ({len(syms)} symbols, Module.symvers format)")
sys.exit(1 if conflicts else 0)
