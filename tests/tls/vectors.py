# Случайные проверочные данные для tests/tls/vectors.kh: AEAD, RSA, ECDSA, ECDH,
# X25519 — по Python cryptography. Строки: вид, поля в hex, ожидаемый результат.
import hashlib
import os
import random
import sys

from cryptography.hazmat.primitives import hashes, serialization
from cryptography.hazmat.primitives.asymmetric import ec, padding, rsa, x25519
from cryptography.hazmat.primitives.asymmetric.utils import decode_dss_signature
from cryptography.hazmat.primitives.ciphers.aead import AESGCM, ChaCha20Poly1305

random.seed(int(sys.argv[1]) if len(sys.argv) > 1 else 1)
lines = []
for i in range(150):
    kind = ["aes128", "aes256", "chacha"][i % 3]
    key = os.urandom(16 if kind == "aes128" else 32)
    nonce = os.urandom(12)
    aad = os.urandom(random.choice([0, 5, 13, 16, 17, 32]))
    pt = os.urandom(random.choice([0, 1, 15, 16, 17, 63, 64, 65, 255, 1000, 4097]))
    c = ChaCha20Poly1305(key) if kind == "chacha" else AESGCM(key)
    lines.append(f"aead {kind} {key.hex()} {nonce.hex()} {aad.hex() or '-'} {pt.hex() or '-'} {c.encrypt(nonce, pt, aad).hex()}")
for bits in [2048, 3072, 4096]:
    k = rsa.generate_private_key(public_exponent=65537, key_size=bits)
    pn = k.public_key().public_numbers()
    nb = pn.n.to_bytes((pn.n.bit_length() + 7) // 8, "big").hex()
    for hname, h, size in [("sha256", hashes.SHA256(), 32), ("sha384", hashes.SHA384(), 48), ("sha512", hashes.SHA512(), 64)]:
        msg = os.urandom(40)
        d = hashlib.new(hname, msg).digest()
        bad = bytes([d[0] ^ 1]) + d[1:]
        s1 = k.sign(msg, padding.PKCS1v15(), h).hex()
        s2 = k.sign(msg, padding.PSS(mgf=padding.MGF1(h), salt_length=size), h).hex()
        lines.append(f"pkcs1 {nb} 010001 {d.hex()} {s1} true")
        lines.append(f"pkcs1 {nb} 010001 {bad.hex()} {s1} false")
        lines.append(f"pss {nb} 010001 {d.hex()} {s2} true")
        lines.append(f"pss {nb} 010001 {bad.hex()} {s2} false")
for cid, curve, size in [(23, ec.SECP256R1(), 32), (24, ec.SECP384R1(), 48)]:
    for i in range(8):
        k = ec.generate_private_key(curve)
        pub = k.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint).hex()
        for hname, h in [("sha256", hashes.SHA256()), ("sha384", hashes.SHA384())]:
            msg = os.urandom(40)
            d = hashlib.new(hname, msg).digest()
            r, s = decode_dss_signature(k.sign(msg, ec.ECDSA(h)))
            rb = r.to_bytes((r.bit_length() + 7) // 8, "big").hex()
            sb = s.to_bytes((s.bit_length() + 7) // 8, "big").hex()
            bad = bytes([d[0] ^ 1]) + d[1:]
            lines.append(f"ecdsa {cid} {pub} {d.hex()} {rb} {sb} true")
            lines.append(f"ecdsa {cid} {pub} {bad.hex()} {rb} {sb} false")
        dv = k.private_numbers().private_value.to_bytes(size, "big").hex()
        peer = ec.generate_private_key(curve)
        pp = peer.public_key().public_bytes(serialization.Encoding.X962, serialization.PublicFormat.UncompressedPoint).hex()
        lines.append(f"ecdh {cid} {dv} {pp} {k.exchange(ec.ECDH(), peer.public_key()).hex()}")
for i in range(20):
    a = x25519.X25519PrivateKey.generate()
    b = x25519.X25519PrivateKey.generate()
    ab = a.private_bytes(serialization.Encoding.Raw, serialization.PrivateFormat.Raw, serialization.NoEncryption()).hex()
    bp = b.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw).hex()
    lines.append(f"x25519 {ab} {bp} {a.exchange(b.public_key()).hex()}")
print("\n".join(lines))
