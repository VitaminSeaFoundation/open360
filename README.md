# open360

Open-source tools for editing and reframing Insta360 `.insv` 360° video in DaVinci Resolve (macOS). It works much like
Insta360's Reframe plugin for Premiere Pro, and **nothing is transcoded**: Resolve decodes the
camera-original HEVC directly.

* **Import**: `.insv` clips land in the Media Pool in about 2 s each. The files Resolve reads are a
  symlink (front lens + audio) and an APFS clone (rear lens). Neither takes extra disk space, and the
  camera original is never modified.
* **open360 Reframe** (Fusion Fuse, `Open360Reframe`): GPU stitch, stabilization and reframing in one resampling
  pass, at full lens resolution. Pan / Tilt / Roll / Field of View / Lens Curve are keyframable,
  with presets (Natural, Wide, Fisheye, Tiny Planet) and a 360 equirectangular output mode.
* **Gyro stabilization** from the camera IMU: Off, Smooth, Horizon Lock (FlowState-like) or
  Direction Lock.
* **Lens accessories**: bare lenses, the X6 water lens (measured against Insta360 Studio), lens
  guards, and dive cases.

Tested with an Insta360 X6 (8K 50p, I-Log, water lens) on DaVinci Resolve Studio 21.1.2,
macOS 27 on Apple Silicon.

## Requirements

* macOS 14+ (Apple Silicon or Intel with a Metal GPU)
* DaVinci Resolve 20 or later. Tested with Resolve **Studio** 21.1.2; the free version is untested.
* Xcode Command Line Tools (`xcode-select --install`) to build the helper
* Footage on an APFS volume for zero-copy import (other filesystems fall back to a bit-exact copy)

## Install

```bash
./install.sh            # builds the helper (needs Xcode Command Line Tools) and installs
./install.sh --link     # same, but symlinks the files (development)
./install.sh --uninstall
```

Restart Resolve afterwards. Installed files go under
`~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/`:
`Fuses/Open360Reframe.fuse` and `Scripts/Utility/open360.py` (+ `open360/`).

## Use

1. **Workspace ▸ Scripts ▸ open360**
2. Choose the **Lens accessory** you shot with. The camera does not record it, so you set it here,
   as you would in Insta360 Studio.
3. **Import .insv Files…** or **Import Folder…** (searched recursively; `.lrv` proxies are skipped).
   With *Create a timeline* ticked, you get a timeline that is already set up.
4. Edit as usual: cut, trim, move and add audio. The clips behave like normal clips.
5. For clips you add to a timeline later, run **Apply to Current Timeline** again.
6. To reframe, open a clip in the **Fusion page** and select the `Open360Reframe` tool. Keyframe
   *Pan / Tilt / Roll / Field of View / Lens Curve* in the Inspector, and use the Spline editor for
   easing.
   * *360* tab: stabilization mode, heading offset, stitch settings (accessory, distance, seam
     blend, rear-lens exposure, seam highlight).
   * *Output: 360 Equirect* renders the stitched 360 at 2 × lens resolution (7680×3840 for the X6)
     for VR deliverables. Resolve 21's VR360 tools can take it from there.
7. Color: clips shot in **I-Log** stay log-encoded. Use Resolve 21's Insta360 I-Log color
   management (or a LUT) as you would for any log clip.

### Tips

* Keep the timeline frame rate equal to the clip's (50p here). For mismatched rates, set
  *Source/Comp FPS Ratio* (Fusion ▸ 360 ▸ Source) so the gyro data stays in sync.
* **Stitch distance** should be roughly the distance of subjects at the seam (default 1 m; 0.7 m
  was best for the sample pool clip). The parallax correction is applied only near the seam.
* The helper files live in an `open360_links/` folder next to the footage. On volumes without
  APFS clone support (exFAT SD cards), the rear-lens file falls back to a bit-exact copy. Copying
  footage to an APFS drive first avoids that.

## How it works

```
VID_xxx.insv ── symlink  VID_xxx.mp4  ─────── MediaIn1 (timeline clip, audio) ─┐
     │       └─ APFS clone VID_xxx_lens1.mp4 ─ MediaIn  (expression-locked)  ──┤
     │                                                                         ├─ Open360Reframe ─ MediaOut
     └─ open360-stitch --analyze ─ VID_xxx.open360.lua (calibration, gyro) ──┘   (Fuse, GPU)
```

* **Why two files?** Resolve only decodes the *first* video track of a file, it rejects the
  `.insv` extension, and it ignores external data references. The X6 stores each lens as its own
  HEVC track. The clone keeps every media byte shared with the original and replaces only the
  13 KB movie header, so its only video track is the rear lens.
* **Calibration** comes from the `.insv` trailer (record 0x101): the extended 56-value Mei
  omnidirectional model (ξ, f, c, k1–k4, tangential p1/p2, thin-prism s1–s4, lens rotations, the
  32 mm baseline) and the focal crop window (protobuf field 27, 7744 → 7680).
* **Stabilization**: the 1 kHz IMU (record 0x300, ±2000 °/s / ±32 g from field 65) is integrated
  with a gravity complementary filter, and a per-frame rotation is computed for each mode and synced
  to the exposure timestamps (record 0x400). The X6 IMU→camera axes (`z,-x,y`, gyro sign inverted)
  were measured on this footage: visual frame-to-frame registration plus long-term gravity
  tracking.
* **Reframe projection**: a general perspective camera (eye at distance *d* behind the sphere
  centre). Lens Curve 0 is rectilinear, 1 is stereographic (tiny planet), and values in between
  give a GoPro/Insta360-style "natural" look.

### Accuracy vs Insta360 Studio

Measured on the sample clip (X6 + water lens, 2048×1024, after aligning orientation), frames 250 / 650:

| model | PSNR overall | PSNR seam band |
|---|---|---|
| bare-lens calibration only | 25.1 / 25.2 dB | 33.3 / 32.6 dB |
| + water-lens profile, 0.7 m seam-local parallax | **32.4 / 31.3 dB** | **36.8 / 33.4 dB** |
| same, rendered by the Fuse inside Resolve (frame 250) | 32.2 dB | 36.5 dB |

For comparison, insv-stitch reports ~22 dB against its Studio ground truth (X5). Studio also uses
optical-flow seam blending, which this tool does not.

## Command-line helper

`stitcher/` (Swift + Metal) holds the analyzer and a standalone renderer. The renderer is optional.
You can use it to make 360 masters or proxies outside Resolve:

```bash
stitcher/.build/release/open360-stitch VID.insv --info
stitcher/.build/release/open360-stitch VID.insv --analyze VID.open360.lua --accessory water
stitcher/.build/release/open360-stitch VID.insv -o VID_360.mov --codec prores422 \
    --stabilize horizon --accessory water --distance 0.7 --proxy VID_proxy.mov
```

It writes ProRes/HEVC 10-bit with audio passthrough and Google spherical (V1 + V2) metadata.

## Limitations / next steps

* Verified on the Insta360 X6 only. X5 files use the same trailer layout and should work, but the
  X5 IMU axes are unverified here. Older cameras (X3/X4, single-track side-by-side files) need
  their calibration layout added.
* No optical-flow seam alignment and no rolling-shutter correction yet. The readout time (field 25,
  15.4 ms on the X6) is already parsed and stored in the sidecar.
* The water-lens profile was fitted on a single clip. The guard and dive-case profiles come from
  Insta360's X5 tables. "Auto-detect" of the accessory from the seam is unreliable on half-submerged
  shots.
* The very first render of a newly set-up comp can show the unprocessed front lens for one frame.
  Scrubbing or playing refreshes it. Final renders are unaffected once the comp has been evaluated.
* Reframe controls live in the Fusion page inspector, because Edit-page effects only receive
  timeline-resolution images, which would waste the 8K source.

## Development

See [CONTRIBUTING.md](CONTRIBUTING.md): code layout, the development loop, and how to add a camera
or lens accessory using `tools/compare_ground_truth.py` against an Insta360 Studio export. Sample
footage is not included in the repository.

## License

[MIT](LICENSE). Insta360 is a trademark of Arashi Vision Inc. and DaVinci Resolve is a trademark of
Blackmagic Design. This project is not affiliated with or endorsed by either company. It reads
`.insv` files using publicly observable file structure only and contains no Insta360 or Blackmagic
code.

