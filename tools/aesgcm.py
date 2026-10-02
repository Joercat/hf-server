#!/usr/bin/env python3
"""
aesgcm.py - AES-256-GCM, in pure Python, so the client patcher needs nothing
installed.  Used only at build time: the *client* decrypts the sealed payload
with the browser's own WebCrypto (PBKDF2-SHA512 + AES-GCM), which is why this
file is verified against Node's crypto in the test suite.

    seal(key, iv, data)   -> ciphertext || 16-byte tag
    open_(key, iv, blob)  -> plaintext            (raises on a bad tag/key)

Only the forward AES (encryption) direction is implemented, which is all GCM
needs.  Standard test vectors are in tests/test_verified_client.sh.
"""

_SBOX = None
_RCON = None


def _build_tables():
    global _SBOX, _RCON
    p = q = 1
    sbox = [0] * 256
    while True:                      # generate the AES S-box from GF(2^8)
        p = p ^ ((p << 1) & 0xFF) ^ (0x1B if p & 0x80 else 0)
        q ^= q << 1
        q ^= q << 2
        q ^= q << 4
        q &= 0xFF
        if q & 0x80:
            q ^= 0x09
        x = q ^ ((q << 1) | (q >> 7)) ^ ((q << 2) | (q >> 6)) \
            ^ ((q << 3) | (q >> 5)) ^ ((q << 4) | (q >> 4))
        sbox[p] = (x ^ 0x63) & 0xFF
        if p == 1:
            break
    sbox[0] = 0x63
    _SBOX = sbox
    _RCON = [0x01]
    for _ in range(13):
        _RCON.append(((_RCON[-1] << 1) ^ (0x11B if _RCON[-1] & 0x80 else 0)) & 0xFF)


def _expand_key(key):
    if len(key) != 32:
        raise ValueError("AES-256 needs a 32 byte key")
    w = [list(key[i:i + 4]) for i in range(0, 32, 4)]     # 8 words
    for i in range(8, 60):
        t = list(w[i - 1])
        if i % 8 == 0:
            t = t[1:] + t[:1]
            t = [_SBOX[b] for b in t]
            t[0] ^= _RCON[i // 8 - 1]
        elif i % 8 == 4:
            t = [_SBOX[b] for b in t]
        w.append([w[i - 8][j] ^ t[j] for j in range(4)])
    return [sum(w[4 * r:4 * r + 4], []) for r in range(15)]   # 15 round keys


def _encrypt_block(rk, block):
    s = [block[i] ^ rk[0][i] for i in range(16)]
    for rnd in range(1, 14):
        s = [_SBOX[b] for b in s]
        # ShiftRows (state is column-major: s[c*4+r])
        s = [s[0], s[5], s[10], s[15],
             s[4], s[9], s[14], s[3],
             s[8], s[13], s[2], s[7],
             s[12], s[1], s[6], s[11]]
        d = lambda x: ((x << 1) & 0xFF) ^ (0x1B if x & 0x80 else 0)   # xtime
        t = []
        for c in range(4):
            a = s[4 * c:4 * c + 4]
            # MixColumns: 2a0^3a1^a2^a3, a0^2a1^3a2^a3, ...
            t.extend([d(a[0]) ^ d(a[1]) ^ a[1] ^ a[2] ^ a[3],
                      a[0] ^ d(a[1]) ^ d(a[2]) ^ a[2] ^ a[3],
                      a[0] ^ a[1] ^ d(a[2]) ^ d(a[3]) ^ a[3],
                      d(a[0]) ^ a[0] ^ a[1] ^ a[2] ^ d(a[3])])
        s = [t[i] ^ rk[rnd][i] for i in range(16)]
    s = [_SBOX[b] for b in s]
    s = [s[0], s[5], s[10], s[15],
         s[4], s[9], s[14], s[3],
         s[8], s[13], s[2], s[7],
         s[12], s[1], s[6], s[11]]
    return bytes(s[i] ^ rk[14][i] for i in range(16))


def _gf_mul(x, y):
    """Multiplication in GF(2^128) as GCM defines it."""
    z = 0
    v = y
    for i in range(128):
        if (x >> (127 - i)) & 1:
            z ^= v
        v = (v >> 1) ^ (0xE1000000000000000000000000000000 if v & 1 else 0)
    return z


def _ghash(h, data):
    y = 0
    for i in range(0, len(data), 16):
        block = data[i:i + 16].ljust(16, b"\x00")
        y = _gf_mul(y ^ int.from_bytes(block, "big"), h)
    return y


def _gctr(rk, icb, data):
    """GCTR: the counter is incremented *before* each block (spec: inc32 first)."""
    out = bytearray()
    counter = (int.from_bytes(icb, "big") & ~0xFFFFFFFF) | ((int.from_bytes(icb, "big") + 1) & 0xFFFFFFFF)
    for i in range(0, len(data), 16):
        ks = _encrypt_block(rk, counter.to_bytes(16, "big"))
        chunk = data[i:i + 16]
        out.extend(a ^ b for a, b in zip(chunk, ks))
        counter = (counter & ~0xFFFFFFFF) | ((counter + 1) & 0xFFFFFFFF)
    return bytes(out)


def _seal_py(key, iv, data, aad=b""):
    """Encrypt + authenticate: returns ciphertext followed by the 16 byte tag."""
    if _SBOX is None:
        _build_tables()
    if len(iv) != 12:
        raise ValueError("this implementation uses 96 bit IVs")
    rk = _expand_key(key)
    h = int.from_bytes(_encrypt_block(rk, b"\x00" * 16), "big")
    j0 = iv + b"\x00\x00\x00\x01"
    ct = _gctr(rk, j0, data)
    # GHASH over AAD || ciphertext || lengths
    pad = lambda b: b + b"\x00" * (-len(b) % 16)
    lengths = (len(aad) * 8).to_bytes(8, "big") + (len(ct) * 8).to_bytes(8, "big")
    s = _ghash(h, pad(aad) + pad(ct) + lengths)
    tag = bytes(a ^ b for a, b in zip(s.to_bytes(16, "big"), _encrypt_block(rk, j0)))
    return ct + tag


def _open_py(key, iv, blob, aad=b""):
    """Verify the tag and decrypt.  Raises ValueError when it does not match."""
    if len(blob) < 16:
        raise ValueError("sealed payload is too short")
    ct, tag = blob[:-16], blob[-16:]
    if _SBOX is None:
        _build_tables()
    if len(iv) != 12:
        raise ValueError("this implementation uses 96 bit IVs")
    rk = _expand_key(key)
    h = int.from_bytes(_encrypt_block(rk, b"\x00" * 16), "big")
    j0 = iv + b"\x00\x00\x00\x01"
    pad = lambda b: b + b"\x00" * (-len(b) % 16)
    lengths = (len(aad) * 8).to_bytes(8, "big") + (len(ct) * 8).to_bytes(8, "big")
    s = _ghash(h, pad(aad) + pad(ct) + lengths)
    expect = bytes(a ^ b for a, b in zip(s.to_bytes(16, "big"), _encrypt_block(rk, j0)))
    if expect != tag:
        raise ValueError("wrong key or damaged file (authentication failed)")
    return _gctr(rk, j0, ct)


def pbkdf2_key(user, password, salt, iterations, dklen=32):
    """The key the client derives: PBKDF2-HMAC-SHA512 over 'user\\0password'."""
    import hashlib
    return hashlib.pbkdf2_hmac("sha512", (user + "\x00" + password).encode("utf-8"),
                               salt, iterations, dklen)


if __name__ == "__main__":       # quick self-test with an AES-GCM vector
    key = bytes(range(32))
    iv = bytes(range(12))
    ct = seal(key, iv, b"hello world" * 7)
    assert open_(key, iv, ct) == b"hello world" * 7
    try:
        open_(key, iv, ct[:-1] + bytes([ct[-1] ^ 1]))
        raise SystemExit("tag check failed to detect tampering")
    except ValueError:
        pass
    print("aesgcm self-test OK (%d bytes sealed)" % len(ct))


# --------------------------------------------------------------------------- #
# backend dispatch: use a fast implementation when one is available, and
# always fall back to the pure Python one above (which needs nothing at all).
# --------------------------------------------------------------------------- #
_NODE_HELPER = r"""
const fs = require('fs'), crypto = require('crypto');
const j = JSON.parse(fs.readFileSync(0, 'utf8'));
const key = Buffer.from(j.key, 'hex'), iv = Buffer.from(j.iv, 'hex');
const data = Buffer.from(j.data, 'base64');
if (j.op === 'seal') {
  const c = crypto.createCipheriv('aes-256-gcm', key, iv);
  const ct = Buffer.concat([c.update(data), c.final(), c.getAuthTag()]);
  process.stdout.write(ct.toString('base64'));
} else {
  const blob = data, tag = blob.subarray(-16);
  const d = crypto.createDecipheriv('aes-256-gcm', key, iv);
  d.setAuthTag(tag);
  try {
    process.stdout.write(Buffer.concat([d.update(blob.subarray(0, -16)), d.final()]).toString('base64'));
  } catch (e) { process.exit(3); }
}
"""


def _backend():
    """Pick a backend once: node > cryptography > pycryptodome > pure python."""
    import shutil
    if getattr(_backend, "_pick", None):
        return _backend._pick
    pick = "pure"
    if shutil.which("node"):
        pick = "node"
    else:
        try:
            from cryptography.hazmat.primitives.ciphers.aead import AESGCM  # noqa
            pick = "cryptography"
        except Exception:
            try:
                from Crypto.Cipher import AES  # noqa
                pick = "pycryptodome"
            except Exception:
                pick = "pure"
    _backend._pick = pick
    return pick


def backend_name():
    return _backend()


def _node(op, key, iv, data):
    import base64
    import json
    import subprocess
    payload = json.dumps({"op": op, "key": key.hex(), "iv": iv.hex(),
                          "data": base64.b64encode(data).decode()})
    proc = subprocess.run(["node", "-e", _NODE_HELPER], input=payload.encode(),
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        raise ValueError("decryption failed (node backend, rc=%d)" % proc.returncode)
    return base64.b64decode(proc.stdout)


def seal(key, iv, data, aad=b""):
    if aad:
        raise ValueError("this helper does not use associated data")
    name = _backend()
    if name == "node":
        return _node("seal", key, iv, data)
    if name == "cryptography":
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        return AESGCM(key).encrypt(iv, data, None)
    if name == "pycryptodome":
        from Crypto.Cipher import AES
        c = AES.new(key, AES.MODE_GCM, nonce=iv)
        ct, tag = c.encrypt_and_digest(data)
        return ct + tag
    return _seal_py(key, iv, data, aad)


def open_(key, iv, blob, aad=b""):
    if aad:
        raise ValueError("this helper does not use associated data")
    name = _backend()
    if name == "node":
        return _node("open", key, iv, blob)
    if name == "cryptography":
        from cryptography.hazmat.primitives.ciphers.aead import AESGCM
        return AESGCM(key).decrypt(iv, blob, None)
    if name == "pycryptodome":
        from Crypto.Cipher import AES
        c = AES.new(key, AES.MODE_GCM, nonce=iv)
        c.update(b"")
        pt = c.decrypt_and_verify(blob[:-16], blob[-16:])
        return pt
    return _open_py(key, iv, blob, aad)
