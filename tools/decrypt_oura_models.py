#!/usr/bin/env python3
"""Decrypt Oura on-device models.

File format: [12-byte IV][AES-256-GCM ciphertext + 16-byte tag]
(see docs/algorithms/sleepnet.md). The key comes from the environment,
never from a file in the repo.

Usage:
  OURA_MODEL_KEY='<base64 or hex>' python3 tools/decrypt_oura_models.py <enc_dir> [out_dir]
Default out_dir: notes/models (gitignored).
"""
import base64
import os
import sys
from pathlib import Path

try:
    from cryptography.exceptions import InvalidTag
    from cryptography.hazmat.primitives.ciphers.aead import AESGCM
except ImportError:  # pragma: no cover
    sys.exit("pip3 install cryptography")


def load_key() -> bytes:
    raw = os.environ.get("OURA_MODEL_KEY", "").strip()
    if not raw:
        sys.exit("set OURA_MODEL_KEY (base64 or hex, 32 bytes)")
    try:
        key = bytes.fromhex(raw)
    except ValueError:
        key = base64.b64decode(raw)
    if len(key) != 32:
        sys.exit(f"key is {len(key)} bytes, need 32")
    return key


def main() -> int:
    if len(sys.argv) < 2:
        sys.exit(__doc__)
    src = Path(sys.argv[1])
    dst = (
        Path(sys.argv[2])
        if len(sys.argv) > 2
        else Path(__file__).resolve().parents[1] / "notes" / "models"
    )
    dst.mkdir(parents=True, exist_ok=True)
    aes = AESGCM(load_key())
    ok = bad = 0
    for f in sorted(src.glob("*.enc")):
        data = f.read_bytes()
        iv, ct = data[:12], data[12:]
        try:
            pt = aes.decrypt(iv, ct, None)
        except InvalidTag:
            print(f"FAIL  {f.name}  (other key label)")
            bad += 1
            continue
        out = dst / f.name[:-4]  # strip ".enc"
        out.write_bytes(pt)
        kind = "zip/torchscript" if pt[:2] == b"PK" else f"magic {pt[:4]!r}"
        print(f"ok    {out.name:48s} {len(pt):>10d} B  {kind}")
        ok += 1
    print(f"\n{ok} decrypted, {bad} failed -> {dst}")
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main())
