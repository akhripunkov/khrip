import struct, sys
# Compare the code segments of two khc binaries: every differing byte must lie
# inside a 4-byte little-endian immediate that points into DATA (0x20000000+) in
# both images (descriptor and string addresses moved), otherwise report it.
def code(path):
    b = open(path, 'rb').read()
    # program header 0: code, file size at 96
    filesz = struct.unpack_from('<Q', b, 96)[0]
    return b[176:filesz]
a, b = code(sys.argv[1]), code(sys.argv[2])
if len(a) != len(b):
    print('code size differs', len(a), len(b)); sys.exit(1)
i = 0; other = 0; moved = 0; lines = 0
while i < len(a):
    if a[i] != b[i]:
        ok = False
        for s in range(max(0, i - 3), i + 1):
            if s + 4 <= len(a):
                va = struct.unpack_from('<I', a, s)[0]; vb = struct.unpack_from('<I', b, s)[0]
                if 0x20000000 <= va < 0x30000000 and 0x20000000 <= vb < 0x30000000:
                    ok = True; moved += 1; i = s + 4; break
        if not ok:
            # место паники: mov esi, (номер файла << 24) | строка
            for s2 in range(max(0, i - 3), i + 1):
                if s2 >= 1 and a[s2 - 1] == 0xBE and b[s2 - 1] == 0xBE and s2 + 4 <= len(a):
                    va = struct.unpack_from('<I', a, s2)[0]; vb = struct.unpack_from('<I', b, s2)[0]
                    if va >> 24 == vb >> 24 and va >> 24 > 0 and (va & 0xFFFFFF) < 100000 and (vb & 0xFFFFFF) < 100000:
                        ok = True; lines += 1; i = s2 + 4; break
        if not ok:
            other += 1; i += 1
    else:
        i += 1
print(f'{len(a)} code bytes; {moved} data addresses moved; {lines} panic line numbers; {other} other differences')
