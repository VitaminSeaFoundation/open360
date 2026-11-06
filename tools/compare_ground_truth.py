#!/usr/bin/env python3
"""
Compare open360-stitch output against an Insta360 Studio export ("ground truth").

Renders one frame of the .insv unstabilized, solves for the global rotation that aligns it with
the Studio frame (Studio output is usually stabilized / re-oriented), then reports PSNR over the
whole sphere (|lat| < 75 deg) and in the seam band (|lens-axis elevation| < 8 deg).

Use it to validate a new camera model, lens accessory profile or stitch setting:

    python3 tools/compare_ground_truth.py CLIP.insv STUDIO_EXPORT.mp4 --frame 250 \
        -- --accessory water --distance 0.7

Everything after "--" is passed to open360-stitch. Requires: numpy, scipy, pillow, ffmpeg.
Export the Studio ground truth as equirectangular 360 at the clip's native frame rate.
"""
import argparse
import json
import os
import subprocess
import sys
import tempfile

import numpy as np
from PIL import Image
from scipy.ndimage import map_coordinates
from scipy.optimize import minimize

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
DEFAULT_BIN = os.path.join(ROOT, "stitcher", ".build", "release", "open360-stitch")


def ffmpeg_frame(src, n, w, h, out):
    subprocess.run(["ffmpeg", "-v", "error", "-y", "-i", src,
                    "-vf", "select=eq(n\\,%d),scale=%d:%d:flags=area" % (n, w, h),
                    "-frames:v", "1", out], check=True)
    return np.asarray(Image.open(out).convert("L"), np.float32)


def rotm(a, b, c):
    ca, sa, cb, sb, cc, sc = np.cos(a), np.sin(a), np.cos(b), np.sin(b), np.cos(c), np.sin(c)
    ry = np.array([[cb, 0, sb], [0, 1, 0], [-sb, 0, cb]])
    rx = np.array([[1, 0, 0], [0, ca, -sa], [0, sa, ca]])
    rz = np.array([[cc, -sc, 0], [sc, cc, 0], [0, 0, 1]])
    return ry @ rx @ rz


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("insv")
    ap.add_argument("ground_truth")
    ap.add_argument("--frame", type=int, default=250)
    ap.add_argument("--gt-offset", type=int, default=0, help="ground-truth frame = frame + offset")
    ap.add_argument("--width", type=int, default=2048, help="comparison width (height = width/2)")
    ap.add_argument("--bin", default=DEFAULT_BIN)
    ap.add_argument("--save", help="write aligned / diff images with this prefix")
    argv = sys.argv[1:]
    extra = []
    if "--" in argv:
        i = argv.index("--")
        argv, extra = argv[:i], argv[i + 1:]
    a = ap.parse_args(argv)
    W, H = a.width, a.width // 2

    with tempfile.TemporaryDirectory() as tmp:
        gt = ffmpeg_frame(a.ground_truth, a.frame + a.gt_offset, W, H, os.path.join(tmp, "gt.png"))
        info = subprocess.run([a.bin, a.insv, "--info", "-q"], capture_output=True, text=True, check=True).stdout
        fps = json.loads(info)["fps"]
        mov = os.path.join(tmp, "ours.mov")
        subprocess.run([a.bin, a.insv, "-o", mov, "--codec", "prores422", "--width", str(2 * W),
                        "--start", str(a.frame / fps), "--frames", "1", "--stabilize", "off", "-y", "-q"] + extra,
                       check=True, stdout=subprocess.DEVNULL)
        ours = ffmpeg_frame(mov, 0, W, H, os.path.join(tmp, "ours.png"))

    lon = (np.arange(W) + .5) / W * 2 * np.pi - np.pi
    lat = np.pi / 2 - (np.arange(H) + .5) / H * np.pi
    LON, LAT = np.meshgrid(lon, lat)
    D = np.stack([np.cos(LAT) * np.sin(LON), np.sin(LAT), np.cos(LAT) * np.cos(LON)], -1)
    band = np.abs(LAT) < np.radians(75)

    def warp(R, step=1):
        d = D[::step, ::step] @ R.T
        lo = np.arctan2(d[..., 0], d[..., 2])
        la = np.arcsin(np.clip(d[..., 1], -1, 1))
        x = (lo + np.pi) / (2 * np.pi) * W - .5
        y = (np.pi / 2 - la) / np.pi * H - .5
        return map_coordinates(ours, [y, x % W], order=1, mode="wrap"), d

    def loss(q, step=4):
        w, _ = warp(rotm(*q), step)
        return np.abs(w - gt[::step, ::step])[band[::step, ::step]].mean()

    yaw0 = min((loss([0, y, 0], 8), y) for y in np.radians(np.arange(-180, 180, 5)))[1]
    r = minimize(loss, [0, yaw0, 0], method="Powell", options=dict(xtol=1e-4, ftol=1e-4))
    r = minimize(lambda q: loss(q, 2), r.x, method="Powell", options=dict(xtol=1e-5, ftol=1e-5))
    w, d = warp(rotm(*r.x))
    seam = (np.abs(np.arcsin(np.clip(d[..., 2], -1, 1))) < np.radians(8)) & band

    def psnr(m):
        return 10 * np.log10(255 ** 2 / ((w - gt) ** 2)[m].mean())

    print("frame %d  alignment rot (pitch, yaw, roll) = %s deg" % (a.frame, np.round(np.degrees(r.x), 2)))
    print("PSNR overall %.2f dB   seam band %.2f dB   mean abs err %.3f" % (psnr(band), psnr(seam), np.abs(w - gt)[band].mean()))
    if a.save:
        Image.fromarray(w.clip(0, 255).astype(np.uint8)).save(a.save + "_aligned.png")
        Image.fromarray(np.clip(np.abs(w - gt) * 4, 0, 255).astype(np.uint8)).save(a.save + "_diff.png")


if __name__ == "__main__":
    sys.exit(main())
