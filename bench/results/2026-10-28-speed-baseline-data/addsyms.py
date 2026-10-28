"""Таблица символов для бинарника khc: callgrind и perf видят имена функций.

    khc --sizes -o server main.kh > sizes.txt
    python3 addsyms.py server sizes.txt server.sym

khc пишет ELF без заголовков разделов. Скрипт копирует файл и дописывает в
конец .text (весь сегмент кода), .symtab, .strtab и .shstrtab; загружаемые
сегменты не меняются, программа работает так же. Строки --sizes:
«<размер> <имя> @<адрес>».
"""
import struct
import sys

src, sizes, dst = sys.argv[1:4]
data = bytearray(open(src, "rb").read())
syms = []
for line in open(sizes):
    parts = line.split()
    if len(parts) == 3 and parts[2].startswith("@"):
        syms.append((parts[1], int(parts[2][1:]), int(parts[0])))
syms.sort(key=lambda s: s[1])

# сегмент кода: первый PT_LOAD с флагом X
phoff = struct.unpack_from("<Q", data, 0x20)[0]
phnum = struct.unpack_from("<H", data, 0x38)[0]
text = None
for i in range(phnum):
    p_type, p_flags, p_off, p_vaddr, _, p_filesz, _, _ = struct.unpack_from("<IIQQQQQQ", data, phoff + i * 56)
    if p_type == 1 and p_flags & 1:
        text = (p_off, p_vaddr, p_filesz)
        break
assert text, "нет сегмента кода"

strtab = bytearray(b"\0")
symtab = bytearray(24)  # нулевой символ
for name, addr, size in syms:
    off = len(strtab)
    strtab += name.encode() + b"\0"
    # STB_GLOBAL, STT_FUNC; раздел 1 (.text)
    symtab += struct.pack("<IBBHQQ", off, 0x12, 0, 1, addr, size)
shstr = bytearray(b"\0")
names = {}
for n in (".text", ".symtab", ".strtab", ".shstrtab"):
    names[n] = len(shstr)
    shstr += n.encode() + b"\0"


def align(n):
    while len(data) % n:
        data.append(0)


align(8)
sym_off = len(data)
data += symtab
str_off = len(data)
data += strtab
shs_off = len(data)
data += shstr
align(8)
sh_off = len(data)


def sh(name, typ, flags, addr, off, size, link, info, al, ent):
    data.extend(struct.pack("<IIQQQQIIQQ", name, typ, flags, addr, off, size, link, info, al, ent))


sh(0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
sh(names[".text"], 1, 6, text[1], text[0], text[2], 0, 0, 16, 0)
sh(names[".symtab"], 2, 0, 0, sym_off, len(symtab), 3, 1, 8, 24)
sh(names[".strtab"], 3, 0, 0, str_off, len(strtab), 0, 0, 1, 0)
sh(names[".shstrtab"], 3, 0, 0, shs_off, len(shstr), 0, 0, 1, 0)
struct.pack_into("<Q", data, 0x28, sh_off)
struct.pack_into("<HHH", data, 0x3A, 64, 5, 4)
open(dst, "wb").write(data)
import os
os.chmod(dst, 0o755)
print(f"{len(syms)} символов → {dst}", file=sys.stderr)
