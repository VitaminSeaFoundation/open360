# Contributing

Thanks for helping. The most valuable contributions are **support for more cameras and lens
accessories**, which need real footage to verify.

## Layout

| path | what |
|---|---|
| `stitcher/` | Swift + Metal CLI `open360-stitch`: .insv trailer parser, IMU stabilization, analyzer (`--analyze` writes the Fuse sidecar), standalone renderer |
| `resolve/Fuses/Open360Reframe.fuse` | Fusion Fuse: GPU stitch + stabilization + reframe (DCTL-style kernel) |
| `resolve/Scripts/Utility/` | Resolve Workspace script (UI) and `open360/` Python modules (zero-copy lens files, media pool, Fusion comp setup) |
| `tools/compare_ground_truth.py` | PSNR comparison against an Insta360 Studio export |
| `install.sh` | build + install (`--link` for development) |

The lens model lives in two places that must stay in sync: `Shaders.swift` (Metal) and the kernel in
`Open360Reframe.fuse`. Lens parameters are passed normalised to the lens image size (see the layout
comments at the top of both).

## Development loop

```bash
./install.sh --link                   # symlink into Resolve's folders
cd stitcher && swift build -c release # rebuild the helper
```

* Fuse changes need a Resolve restart. Errors are logged to `~/Library/Logs/Open360Reframe.log`
  and to the Fusion console.
* Python module changes are picked up the next time the Workspace script runs.
* Edit a timeline clip's comp only while it is the **current comp on the Fusion page**. Comps fetched
  with `TimelineItem.GetFusionCompByIndex()` for other clips accept edits that Resolve neither renders
  nor saves (see `_open_item_comp`).

## Adding a camera

1. Run `open360-stitch CLIP.insv --info` and check that the trailer and calibration parse.
   Supported layout: two lenses, 27 values each (`xi fx fy cx cy yaw pitch roll tx ty tz k1..k4 _
   p1 p2 s1..s4 _ _ w h type`).
2. **IMU axes** (`--imu-map`, default `z,-x,y` for the X6): use a clip with deliberate pan, tilt and
   roll. Integrate the gyro (`--stabilize lock`) and check that the world stays still. Gravity
   (accelerometer) must read +Y when the camera is upright.
3. **Ground truth**: export the same clip from Insta360 Studio as an 8K equirectangular video at the
   native frame rate, then:

   ```bash
   python3 tools/compare_ground_truth.py CLIP.insv STUDIO.mp4 --frame 250 -- --accessory bare --distance 1
   ```

   Report PSNR for a few frames in the PR. The X6 reaches ~32 dB overall and ~36 dB at the seam.
4. Lens accessories (guards, water lens, dive cases) are not recorded by the camera. New profiles are
   fitted against Studio output. Add them to `LensAccessory` (Swift) and to `radialPresets` /
   `accessoryProfiles` (Fuse).

**Do not commit footage**: it is large and usually shows people. Share sample clips via a link in the
issue instead, with the consent of the people shown.

## Style

* Swift: keep `open360-stitch` dependency-free (system frameworks only).
* Python: standard library only. Resolve runs these modules in its own interpreter.
* Lua Fuse: no globals beyond the Fuse callbacks.
