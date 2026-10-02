#!/usr/bin/env python3
"""Independent test vectors for QuickShareCore (UKEY2 / D2D key derivation, PIN, AES-CBC, HMAC).

This is a second implementation, written from docs/PROTOCOL_NOTES.md section 4-5 and Google's
Java UKEY2 sources, using Python's `cryptography` package for P-256 and AES. The Swift tests in
Packages/QuickShareCore/Tests/QuickShareCoreTests/KeyDerivationVectorTests.swift embed its output.

Usage: python3 scripts/gen-test-vectors.py
"""
import hashlib
import hmac

from cryptography.hazmat.primitives.asymmetric import ec
from cryptography.hazmat.primitives.ciphers import Cipher, algorithms, modes
from cryptography.hazmat.primitives import padding


def hkdf(ikm: bytes, salt: bytes, info: bytes, length: int = 32) -> bytes:
    prk = hmac.new(salt if salt else b"\x00" * 32, ikm, hashlib.sha256).digest()
    out, t, i = b"", b"", 1
    while len(out) < length:
        t = hmac.new(prk, t + info + bytes([i]), hashlib.sha256).digest()
        out += t
        i += 1
    return out[:length]


def c_mod(a: int, m: int) -> int:
    """C/Java/Swift truncating remainder (Python's % floors)."""
    r = abs(a) % m
    return -r if a < 0 else r


def pin(auth: bytes) -> str:
    h, mult = 0, 1
    for b in auth:
        signed = b - 256 if b > 127 else b
        h = c_mod(h + signed * mult, 9973)
        mult = c_mod(mult * 31, 9973)
    return "%04d" % abs(h)


def priv(scalar: int) -> ec.EllipticCurvePrivateKey:
    return ec.derive_private_key(scalar, ec.SECP256R1())


def raw_scalar(k: ec.EllipticCurvePrivateKey) -> bytes:
    return k.private_numbers().private_value.to_bytes(32, "big")


def ecdh_x(a: ec.EllipticCurvePrivateKey, b: ec.EllipticCurvePrivateKey) -> bytes:
    return a.exchange(ec.ECDH(), b.public_key())  # always 32 bytes (fixed-length x)


def hexs(b: bytes) -> str:
    return b.hex()


def main():
    client = priv(0x1F2E3D4C5B6A79880102030405060708090A0B0C0D0E0F101112131415161718)
    server = priv(0x0102030405060708090A0B0C0D0E0F10111213141516171819202122232425FF)
    m1 = bytes.fromhex("08021a20") + bytes(range(32))      # arbitrary fixed "ClientInit" bytes
    m2 = bytes.fromhex("08031a20") + bytes(range(32, 64))  # arbitrary fixed "ServerInit" bytes

    x = ecdh_x(client, server)
    dhs = hashlib.sha256(x).digest()
    auth = hkdf(dhs, b"UKEY2 v1 auth", m1 + m2)
    auth_nul = hkdf(dhs, b"UKEY2 v1 auth\x00", m1 + m2)
    nxt = hkdf(dhs, b"UKEY2 v1 next", m1 + m2)
    d2d_salt = hashlib.sha256(b"D2D").digest()
    sm_salt = hashlib.sha256(b"SecureMessage").digest()
    d2d_client = hkdf(nxt, d2d_salt, b"client")
    d2d_server = hkdf(nxt, d2d_salt, b"server")

    print("// fixed handshake")
    print("clientScalar =", hexs(raw_scalar(client)))
    print("serverScalar =", hexs(raw_scalar(server)))
    print("m1 =", hexs(m1))
    print("m2 =", hexs(m2))
    print("sharedX =", hexs(x))
    print("dhs =", hexs(dhs))
    print("authString =", hexs(auth))
    print("authStringNul =", hexs(auth_nul))
    print("nextSecret =", hexs(nxt))
    print("pin =", pin(auth))
    print("pinNul =", pin(auth_nul))
    print("clientEnc =", hexs(hkdf(d2d_client, sm_salt, b"ENC:2")))
    print("clientSig =", hexs(hkdf(d2d_client, sm_salt, b"SIG:1")))
    print("serverEnc =", hexs(hkdf(d2d_server, sm_salt, b"ENC:2")))
    print("serverSig =", hexs(hkdf(d2d_server, sm_salt, b"SIG:1")))

    # AES-256-CBC/PKCS7 + HMAC-SHA256 with fixed key, IV and plaintext.
    key = hkdf(d2d_server, sm_salt, b"ENC:2")
    iv = bytes(range(16))
    plaintext = b"squick-share test vector: AES-256-CBC with PKCS#7 padding"
    padder = padding.PKCS7(128).padder()
    enc = Cipher(algorithms.AES(key), modes.CBC(iv)).encryptor()
    ciphertext = enc.update(padder.update(plaintext) + padder.finalize()) + enc.finalize()
    print("cbcPlaintext =", hexs(plaintext))
    print("cbcIV =", hexs(iv))
    print("cbcCiphertext =", hexs(ciphertext))
    print("hmacOfCiphertext(serverSig) =", hexs(hmac.new(hkdf(d2d_server, sm_salt, b"SIG:1"), ciphertext, hashlib.sha256).digest()))

    # A server key whose ECDH x-coordinate with `client` starts with 0x00.
    scalar = 0x0102030405060708090A0B0C0D0E0F10111213141516171819202122232425FF
    while True:
        scalar += 1
        candidate = priv(scalar)
        x0 = ecdh_x(client, candidate)
        if x0[0] == 0:
            break
    print("// leading-zero shared secret")
    print("zeroServerScalar =", hexs(raw_scalar(candidate)))
    print("zeroSharedX =", hexs(x0))
    print("zeroDHS =", hexs(hashlib.sha256(x0).digest()))
    print("zeroDHSIfStripped =", hexs(hashlib.sha256(x0.lstrip(b"\x00")).digest()))
    z_auth = hkdf(hashlib.sha256(x0).digest(), b"UKEY2 v1 auth", m1 + m2)
    print("zeroAuthString =", hexs(z_auth))
    print("zeroPin =", pin(z_auth))

    # PIN edge cases.
    print("// pin edge cases")
    print("pinAllFF =", pin(b"\xff" * 32))
    print("pinAll00 =", pin(b"\x00" * 32))
    print("pinAll80 =", pin(b"\x80" * 32))


if __name__ == "__main__":
    main()
