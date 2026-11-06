# Changelog

## 0.1.0 — 2026-11-06

First public version.

- Import Insta360 `.insv` into DaVinci Resolve without transcoding (symlink + APFS clone lens files).
- `Open360Reframe` Fusion Fuse: GPU stitch (extended Mei model), gyro stabilization (Off / Smooth /
  Horizon Lock / Direction Lock) and keyframable reframing (Pan, Tilt, Roll, FOV, Lens Curve,
  presets), plus a 360 equirectangular output.
- Lens accessories: bare, X6 water lens (fitted against Insta360 Studio), guards and dive cases
  (Insta360 X5 profiles).
- Seam-local parallax correction (stitch distance) and lens-to-lens exposure matching.
- `open360-stitch` CLI: clip info, analysis sidecar, standalone ProRes/HEVC renderer with spherical
  metadata.
- `tools/compare_ground_truth.py`: PSNR against Insta360 Studio exports.
- Verified on an Insta360 X6 (8K 50p, I-Log) with DaVinci Resolve Studio 21.1.2.
