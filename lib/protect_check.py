#!/usr/bin/env python3
"""Gate layer 2 — will any stock module be refused for EXPORTING a protected symbol?

Usage: protect_check.py <vmlinux|-> <kernel Module.symvers> <protected_module_names_list> <kmi_ref_tree>

  <vmlinux>                      the built kernel: its protected_symbol_exports[]
                                 table is read DIRECTLY — the ground truth the module
                                 loader bsearches. "-" skips it (self-tests only).
  <kernel Module.symvers>        kleaf's kernel_aarch64_Module.symvers: every symbol
                                 exported by vmlinux AND by the GKI modules, with the
                                 owning module path in column 3
  <protected_module_names_list>  the list kleaf generated for THIS build
                                 (CONFIG_MODULE_SIG_PROTECT_LIST), module paths
  <kmi_ref_tree>                 the shipped module tree, as for the other layers

Exit codes, as layers 1 and 3:
    0  CLEAN      no stock module exports a protected symbol
    1  BROKEN     at least one stock module would be refused at load (-EACCES)
    2  VACUOUS    nothing could be checked (missing/empty inputs, empty tree)

WHY THIS LAYER EXISTS. With CONFIG_MODULE_SIG_PROTECT, kernel/module/main.c
refuses any module whose signature does not verify against THIS kernel's key if it
exports a symbol that a listed (protected) GKI module exports:

    if (!mod->sig_ok && is_protected_symbol_export(name))
            return -EACCES;      /* "<mod>: exports protected symbol <sym>" */

The phone's stock rfkill.ko and libarc4.ko are GKI modules, signed with the key of
the build Google made for this phone — which our kernel does not carry. So on our
kernel they are unsigned, they export rfkill_* / arc4_*, and they are refused —
taking cfg80211, mac80211 and the MediaTek Wi-Fi driver down with them. v1 and v2
shipped with no Wi-Fi this way (tester, 2026-10-01): layer 1 checks CRCs, layer 3
checks IMPORTS, and nothing checked EXPORTS.

Every reference module is treated as unsigned: none of them was signed by us, and
a kernel we build never holds the key that signed them.

🪤 The list × Module.symvers join alone is NOT the full set: on this build it gave
437 symbols while the table in vmlinux holds 573 — Module.symvers does not carry the
exports of every protected GKI module (9p, Bluetooth hci_*, wwan, usbnet, kunit…).
So the vmlinux table is read and the two are unioned; the join is kept because the
self-tests and the v2 negative control exercise it.
"""
import sys, os, glob, collections
from elftools.elf.elffile import ELFFile
from elftools.elf.sections import SymbolTableSection

if len(sys.argv) != 5:
    sys.exit("usage: protect_check.py <vmlinux|-> <kernel Module.symvers> <protected_module_names_list> <kmi_ref_tree>")
vmlinux_path, symvers_path, list_path, ref_tree = sys.argv[1:5]


def vacuous(why):
    print(f"RESULT: VACUOUS — {why}. This is NOT a pass.")
    sys.exit(2)


if not os.path.isfile(list_path):
    vacuous(f"no protected-modules list at '{list_path}'")
protected_mods = set()
with open(list_path) as f:
    for ln in f:
        ln = ln.strip()
        if ln and not ln.startswith('#'):
            protected_mods.add(ln[:-3] if ln.endswith('.ko') else ln)

if not os.path.isfile(symvers_path):
    vacuous(f"no Module.symvers at '{symvers_path}'")
owner = {}                                   # protected symbol -> GKI module path
with open(symvers_path) as f:
    for ln in f:
        p = ln.rstrip('\n').split('\t')
        if len(p) >= 3 and p[2] in protected_mods:
            owner[p[1]] = p[2]

print(f"protected list  : {list_path}  [{len(protected_mods)} GKI modules]")
print(f"protected syms  : {len(owner)} attributed to them by Module.symvers")
if protected_mods and not owner:
    vacuous("the list names modules but Module.symvers attributes no export to them "
            "(wrong symvers file?)")


def vmlinux_table(path):
    """protected_symbol_exports[] as built into the kernel (sorted C strings)."""
    import struct
    with open(path, 'rb') as fh:
        ef = ELFFile(fh)
        st = ef.get_section_by_name('.symtab')
        n_sym = st.get_symbol_by_name('protected_symbol_exports_count') if st else None
        t_sym = st.get_symbol_by_name('protected_symbol_exports') if st else None
        if not n_sym or not t_sym:
            return None
        secs = [(x['sh_addr'], x['sh_size'], x.data()) for x in ef.iter_sections()
                if x['sh_type'] != 'SHT_NOBITS' and x['sh_addr']]

        def read(addr, size):
            for a, sz, d in secs:
                if a <= addr < a + sz:
                    return d[addr - a:addr - a + size]
            raise ValueError(f"address {addr:#x} not in any loaded section")
        n = struct.unpack('<Q', read(n_sym[0]['st_value'], 8))[0]
        out = set()
        for i in range(n):
            ptr = struct.unpack('<Q', read(t_sym[0]['st_value'] + 8 * i, 8))[0]
            out.add(read(ptr, 256).split(b'\0')[0].decode())
        return out


if vmlinux_path != '-':
    table = vmlinux_table(vmlinux_path)
    if table is None:
        vacuous(f"no protected_symbol_exports table in '{vmlinux_path}' "
                "(MODULE_SIG_PROTECT on but the table is missing — or not a vmlinux)")
    extra = table - owner.keys()
    print(f"vmlinux table   : {len(table)} protected symbols  "
          f"(+{len(extra)} the Module.symvers join does not know)")
    for sym in extra:
        owner[sym] = '<protected in vmlinux>'
    stale = owner.keys() - table - extra
    if stale and table:
        print(f"  note          : {len(stale)} joined symbols are NOT in the kernel's table "
              f"(e.g. {sorted(stale)[:3]}) — the list or symvers is not from this build?")


def exports(path):
    """Symbols a module exports: one __ksymtab_<name> entry per EXPORT_SYMBOL."""
    with open(path, 'rb') as fh:
        ef = ELFFile(fh)
        st = ef.get_section_by_name('.symtab')
        if not isinstance(st, SymbolTableSection):
            return set()
        return {s.name[len('__ksymtab_'):] for s in st.iter_symbols()
                if s.name.startswith('__ksymtab_')}


kos = sorted(glob.glob(os.path.join(ref_tree, '**', '*.ko'), recursive=True))
if not kos:
    vacuous(f"no .ko under '{ref_tree}'")

per_set = collections.Counter()
bad = []                                     # (tree-relative path, [symbols], owners)
exporting = 0
for k in kos:
    rel = os.path.relpath(k, ref_tree)
    per_set[rel.split(os.sep)[0]] += 1
    ex = exports(k)
    if ex:
        exporting += 1
    hit = sorted(ex & owner.keys())
    if hit:
        bad.append((rel, hit, sorted({owner[s] for s in hit})))

print("module sets     : " + "  ".join(f"{n}x {s}" for s, n in sorted(per_set.items()))
      + f"  [total {len(kos)}]")
print(f"exporting       : {exporting} modules export symbols; each checked against the list")
for rel, hit, owners in bad:
    shown = ' '.join(hit[:4]) + (f' … (+{len(hit) - 4})' if len(hit) > 4 else '')
    print(f"  REFUSED       : {rel} — exports {len(hit)} protected symbol(s) of "
          f"{', '.join(owners)}: {shown}")

if bad:
    print(f"\nRESULT: {len(bad)} stock module(s) would be REFUSED at load (-EACCES, "
          f"\"exports protected symbol\") — and every module depending on them with it. "
          f"Unprotect them in common/modules.bzl (_COMMON_UNPROTECTED_MODULES_LIST), "
          f"do NOT ship")
    sys.exit(1)
print("RESULT: CLEAN — no stock module exports a symbol this kernel protects")
sys.exit(0)
