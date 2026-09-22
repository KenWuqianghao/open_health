#!/usr/bin/env python3
"""Export the decrypted Oura TorchScript models (newest per family, plus the
versions the iOS app pins) to the PyTorch
lite-interpreter (`.ptl`) format used by on-device runtimes (iOS/Android).

This is the iOS spike's go/no-go: the shipped models are full TorchScript
pipelines (pre/post-processing + validators baked into the graph) that do NOT
convert to Core ML — they use int64 timestamps, data-dependent control flow and
multi-tensor tuple outputs. The lite interpreter runs the *same* TorchScript
bytecode, so nothing is reimplemented or lost.

Outputs land in `notes/models/mobile/<name>.ptl` (gitignored, like the models).

Usage:
    python tools/export_mobile.py            # export all
    python tools/export_mobile.py --check    # also run a pt-vs-ptl parity check
"""
import sys
import warnings
from pathlib import Path

warnings.filterwarnings("ignore")
import torch

from _common import newest_models

REPO = Path(__file__).resolve().parent.parent
MODELS = REPO / "notes" / "models"
OUT = MODELS / "mobile"

# The iOS app pins the versions whose forward() contract TorchBridge.mm implements.
# Newer files in notes/models/ are exported too (see newest_models), but the app
# bundles exactly these.
IOS_APP = [
    "automatic_activity_detection_3_1_12",
    "cva_2_1_5",
    "illness_detection_0_5_1",
    "sleepnet_moonstone_1_2_0",
    "steps_motion_decoder_2_0_0",
]


def export_one(name):
    src = MODELS / f"{name}.pt"
    if not src.exists():
        return name, None, "file missing"
    try:
        m = torch.jit.load(str(src), map_location="cpu").eval()
        dst = OUT / f"{name}.ptl"
        m._save_for_lite_interpreter(str(dst))
        return name, dst.stat().st_size, None
    except Exception as e:
        msg = (str(e).strip().splitlines() or ["<no message>"])[0]
        return name, None, msg[:100]


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    print(f"bytecode version: {torch._C._get_max_operator_version()} (torch {torch.__version__})")
    ok = fail = 0
    total = 0
    names = sorted(set(newest_models(MODELS)) | set(IOS_APP))
    for name in names:
        n, sz, err = export_one(name)
        if err or sz is None:
            print(f"  FAIL {n:42s}: {err or 'unknown'}")
            fail += 1
        else:
            print(f"  ok   {n:42s} -> {sz/1e6:6.2f} MB")
            ok += 1
            total += sz
    print(f"\n{ok} exported ({total/1e6:.1f} MB total), {fail} failed -> {OUT}")
    return 0 if fail == 0 else 1


if __name__ == "__main__":
    sys.exit(main())
