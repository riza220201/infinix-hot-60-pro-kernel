#!/usr/bin/env python3
"""Build the symvers a REALISTIC kernel would have, for use as a test control.

Usage: vmlinux-only-symvers.py <full.symvers> <kmi_ref_tree> <out.symvers>

The device-derived symvers (`stock-derived.symvers`) contains every symbol any
stock module imports — including the ones they import from *each other*. A real
kernel's symvers contains only its own exports, so feeding the derived file to
`import_check.py` makes the "from siblings" bucket read 0 and hides whether the
accounting works at all.

This filters the derived symvers down to the symbols that genuinely must come
from vmlinux (imported by some module, exported by none), which is what a real
kernel's symvers looks like for this purpose.

🔑 The asymmetry is itself the point: a derived symvers contains every symbol
anyone referenced; a real kernel's contains only what it exports.
"""
import sys, glob, os, struct
from elftools.elf.elffile import ELFFile

if len(sys.argv) != 4:
    sys.exit("usage: vmlinux-only-symvers.py <full.symvers> <kmi_ref_tree> <out.symvers>")
full, ref, out = sys.argv[1], sys.argv[2], sys.argv[3]

imports, exports = set(), set()
for ko in glob.glob(os.path.join(ref, '**', '*.ko'), recursive=True):
    ef = ELFFile(open(ko, 'rb'))
    sec = ef.get_section_by_name('__versions')
    if sec:
        d = sec.data()
        for i in range(0, len(d), 64):
            c = d[i:i + 64]
            if len(c) < 64:
                break
            nm = c[8:].split(b'\x00')[0].decode('latin1')
            if nm:
                imports.add(nm)
    en = ef.get_section_by_name('__version_ext_names')
    if en:
        for n in en.data().split(b'\x00'):
            if n:
                imports.add(n.decode('latin1'))
    st = ef.get_section_by_name('.symtab')
    if st:
        for s in st.iter_symbols():
            if s.name.startswith('__ksymtab_'):
                exports.add(s.name[len('__ksymtab_'):])

need = imports - exports
n = 0
with open(out, 'w') as f:
    for ln in open(full):
        p = ln.split('\t')
        if len(p) >= 2 and p[1] in need:
            f.write(ln)
            n += 1
print(f"{n} symbols must come from vmlinux "
      f"({len(imports)} imported, {len(exports)} exported by the modules themselves)")
