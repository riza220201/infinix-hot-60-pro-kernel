#!/usr/bin/env python3
"""Account for EVERY symbol the device's stock modules import. Layer 3 of the gate.

Usage: import_check.py <vmlinux.symvers> <kmi_ref_tree> [abi_symbollist]

`kmi_check.py` answers "do the CRCs agree". It cannot answer "will the module
actually resolve", and those are different questions with different failures:

  * a symbol our kernel does not export at all  -> "Unknown symbol" at load
  * a symbol our kernel exports, with the right CRC, that is NOT in the kernel's
    permitted-import list -> -EACCES in resolve_symbol(), because on
    android16-6.12 `CONFIG_TRIM_UNUSED_KSYMS` restricts an unsigned module to
    importing only permitted symbols or symbols from other unsigned modules
    (kernel/module/main.c). **The CRC gate calls that kernel CLEAN.**

So: every import must land in exactly one bucket.

  vmlinux        our kernel exports it            -> fine
  sibling        another stock module exports it  -> fine, resolved at load
  UNRESOLVED     neither                          -> the module will not load

An unresolved residue is not automatically our bug — it can be a pre-existing
stock defect (on the sibling itel RS4, three `dw9781caf_*` symbols were wanted by
a camera module whose provider the OEM never shipped, so it failed to load on
stock exactly as it would on ours). But it must be CHASED TO ZERO and then named,
not waved at: put each one in KMI_UNRESOLVED_EXPECTED with its reason.

With a third argument, also asserts that every vmlinux-provided import appears in
the kernel's symbol list (`abi_symbollist`) — the -EACCES case above.

Exit: 0 accounted for · 1 unresolved or non-permitted · 2 nothing checked
"""
import sys, struct, glob, os, collections
from elftools.elf.elffile import ELFFile

if not 3 <= len(sys.argv) <= 4:
    sys.exit("usage: import_check.py <vmlinux.symvers> <kmi_ref_tree> [abi_symbollist]")
symvers_path, ref_tree = sys.argv[1], sys.argv[2]
symbollist_path = sys.argv[3] if len(sys.argv) == 4 else None

exported_by_vmlinux = set()
with open(symvers_path) as f:
    for ln in f:
        p = ln.split('\t')
        if len(p) >= 2:
            exported_by_vmlinux.add(p[1].strip())


def read_module(path):
    ef = ELFFile(open(path, 'rb'))
    imports = {}
    sec = ef.get_section_by_name('__versions')
    if sec:
        d = sec.data()
        for i in range(0, len(d), 64):
            c = d[i:i + 64]
            if len(c) < 64:
                break
            nm = c[8:].split(b'\x00')[0].decode('latin1')
            if nm:
                imports[nm] = True
    en = ef.get_section_by_name('__version_ext_names')
    if en:
        for n in en.data().split(b'\x00'):
            if n:
                imports[n.decode('latin1')] = True
    exports = set()
    st = ef.get_section_by_name('.symtab')
    if st:
        for s in st.iter_symbols():
            if s.name.startswith('__ksymtab_'):
                exports.add(s.name[len('__ksymtab_'):])
    return imports, exports


kos = sorted(glob.glob(os.path.join(ref_tree, '**', '*.ko'), recursive=True))
imports = collections.defaultdict(set)   # symbol -> importing modules
exported_by_modules = set()
for ko in kos:
    rel = os.path.relpath(ko, ref_tree)
    imp, exp = read_module(ko)
    for nm in imp:
        imports[nm].add(rel)
    exported_by_modules |= exp

if not kos or not imports:
    print(f"RESULT: {len(kos)} modules / {len(imports)} imports — nothing to verify "
          f"(wrong reference tree?). NOT a pass.")
    sys.exit(2)

from_vmlinux = {n for n in imports if n in exported_by_vmlinux}
from_sibling = {n for n in imports if n not in exported_by_vmlinux and n in exported_by_modules}
unresolved = sorted(set(imports) - from_vmlinux - from_sibling)

print(f"reference tree  : {ref_tree}   [{len(kos)} modules]")
print(f"distinct imports: {len(imports)}")
print(f"  from vmlinux  : {len(from_vmlinux)}")
print(f"  from siblings : {len(from_sibling)}  (module-to-module, resolved at load)")
print(f"  UNRESOLVED    : {len(unresolved)}")
print(f"  accounting    : {len(from_vmlinux)} + {len(from_sibling)} + {len(unresolved)} "
      f"= {len(from_vmlinux) + len(from_sibling) + len(unresolved)}  "
      f"(must equal {len(imports)})")

expected = set(os.environ.get('KMI_UNRESOLVED_EXPECTED', '').replace(',', ' ').split())
rc = 0

if unresolved:
    surprises = [n for n in unresolved if n not in expected]
    for n in unresolved[:20]:
        who = sorted(imports[n])
        tag = "declared" if n in expected else "SURPRISE"
        print(f"    {tag}: {n}  <- {', '.join(who[:3])}{' …' if len(who) > 3 else ''}")
    if len(unresolved) > 20:
        print(f"    … and {len(unresolved) - 20} more")
    if surprises:
        print(f"\nRESULT: {len(surprises)} unresolved symbol(s) not declared in "
              f"KMI_UNRESOLVED_EXPECTED — those modules will fail to load.")
        rc = 1
    else:
        print(f"\nnote: all {len(unresolved)} unresolved symbols are declared expected "
              f"(pre-existing stock defects, not regressions).")

# ── the -EACCES case: exported and CRC-correct, but not permitted to import ──
if symbollist_path:
    permitted = set()
    with open(symbollist_path) as f:
        for ln in f:
            ln = ln.strip()
            if ln and not ln.startswith('#') and not ln.startswith('['):
                permitted.add(ln)
    denied = sorted(n for n in from_vmlinux if n not in permitted)
    print(f"permitted list  : {symbollist_path}  [{len(permitted)} symbols]")
    print(f"  vmlinux imports NOT permitted: {len(denied)}")
    for n in denied[:15]:
        print(f"    -EACCES: {n}  <- {sorted(imports[n])[0]}")
    if denied:
        print(f"\nRESULT: {len(denied)} symbol(s) would be refused at resolve_symbol() "
              f"with -EACCES despite correct CRCs.")
        rc = 1

if rc == 0:
    print("RESULT: CLEAN — every stock import is accounted for and permitted")
sys.exit(rc)
