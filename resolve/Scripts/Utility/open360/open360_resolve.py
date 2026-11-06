"""
Insta360 .insv support for DaVinci Resolve - core logic (no UI).

Workflow (no transcoding):
  1. import_insv(): for each .insv, create zero-copy lens files (symlink + APFS clone) plus an
     analysis sidecar (calibration, lens accessory, gyro stabilization), then import the lens-0
     file (with audio) into the media pool. The lens-1 file goes into a sub bin; it is only used
     inside Fusion.
  2. apply_reframe(): for timeline clips that come from an imported .insv, build the clip's Fusion
     comp: MediaIn1 (lens 0) + MediaIn (lens 1, frame-locked) -> Open360Reframe -> MediaOut.
"""
import glob
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__)) if "__file__" in globals() else None
if HERE and HERE not in sys.path:
    sys.path.insert(0, HERE)

import insv_ref  # noqa: E402

LINK_DIR_NAME = "open360_links"
BIN_NAME = "open360 360°"
REAR_BIN_NAME = "rear lens (used by Fusion)"
FUSE_ID = "Fuse.Open360Reframe"
TAG = "open360"

USER_SCRIPTS = os.path.expanduser(
    "~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/open360")
SYSTEM_SCRIPTS = "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/open360"
FALLBACK_CACHE = os.path.expanduser("~/Movies/open360 Links")


def find_helper():
    cands = []
    if HERE:
        cands += [os.path.join(HERE, "bin", "open360-stitch"),
                  os.path.join(HERE, "..", "..", "..", "..", "stitcher", ".build", "release", "open360-stitch")]
    cands += [os.path.join(USER_SCRIPTS, "bin", "open360-stitch"),
              os.path.join(SYSTEM_SCRIPTS, "bin", "open360-stitch"),
              "/usr/local/bin/open360-stitch", "/opt/homebrew/bin/open360-stitch"]
    for c in cands:
        c = os.path.abspath(c)
        if os.path.isfile(c) and os.access(c, os.X_OK):
            return c
    raise RuntimeError("open360-stitch helper not found. Run install.sh again.")


def _writable_dir(d):
    try:
        os.makedirs(d, exist_ok=True)
        probe = os.path.join(d, ".write_test")
        with open(probe, "w") as f:
            f.write("x")
        os.remove(probe)
        return True
    except OSError:
        return False


def link_dir_for(insv_path):
    d = os.path.join(os.path.dirname(os.path.abspath(insv_path)), LINK_DIR_NAME)
    if _writable_dir(d):
        return d
    # read-only media (SD card, locked volume): keep links in the user's Movies folder
    sub = re.sub(r"[^A-Za-z0-9_.-]+", "_", os.path.dirname(os.path.abspath(insv_path)).strip("/"))
    d = os.path.join(FALLBACK_CACHE, sub)
    os.makedirs(d, exist_ok=True)
    return d


def find_insv(paths):
    """Expand files/folders into a sorted list of .insv files (low-res .lrv files are skipped)."""
    out = []
    for p in paths:
        if os.path.isdir(p):
            for f in sorted(glob.glob(os.path.join(p, "**", "*"), recursive=True)):
                if f.lower().endswith(".insv") and LINK_DIR_NAME not in f:
                    out.append(f)
        elif p.lower().endswith(".insv"):
            out.append(p)
    return sorted(set(os.path.abspath(p) for p in out))


ACCESSORIES = [("bare", "Bare lenses"), ("water", "Water lens (X6)"), ("guard", "Lens guards"),
               ("dive-water", "Dive case - underwater"), ("dive-air", "Dive case - in air"),
               ("auto", "Auto-detect (experimental)")]


def prepare(insv_path, log=print, analyze=True, accessory="bare", distance="1"):
    """Create zero-copy lens files + analysis sidecar. Returns dict with paths and info."""
    insv_path = os.path.abspath(insv_path)
    d = link_dir_for(insv_path)
    base = os.path.splitext(os.path.basename(insv_path))[0]
    refs, method = insv_ref.make_lens_files(insv_path, d, base_name=base, log=log)
    sidecar = os.path.join(d, base + ".open360.lua")
    info = {"insv": insv_path, "lens0": refs[0], "lens1": refs[1] if len(refs) > 1 else None,
            "sidecar": sidecar, "lenses": len(refs), "method": method}
    if analyze:
        helper = find_helper()
        cmd = [helper, insv_path, "--analyze", sidecar, "--accessory", accessory, "--distance", str(distance)]
        p = subprocess.run(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True,
                           encoding="utf-8", errors="replace")
        if p.returncode != 0:
            raise RuntimeError("analysis failed for %s:\n%s" % (insv_path, p.stderr.strip()))
        for line in p.stderr.splitlines():
            log("  " + line)
        ip = subprocess.run([helper, insv_path, "--info", "-q"], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True, encoding="utf-8", errors="replace")
        if ip.returncode == 0:
            try:
                info["meta"] = json.loads(ip.stdout)
            except ValueError:
                pass
    return info


# ---------------------------------------------------------------------------- media pool

def _get_or_create_bin(mp, parent, name):
    for f in parent.GetSubFolderList() or []:
        if f.GetName() == name:
            return f
    return mp.AddSubFolder(parent, name)


def _all_clips(folder):
    out = list(folder.GetClipList() or [])
    for sub in folder.GetSubFolderList() or []:
        out += _all_clips(sub)
    return out


def _find_clip_by_path(folder, path):
    for c in _all_clips(folder):
        try:
            if c.GetClipProperty("File Path") == path:
                return c
        except Exception:
            pass
    return None


def import_insv(resolve, paths, log=print, accessory="bare", distance="1"):
    """Import .insv files (or folders) into the current project. Returns list of main clips."""
    project = resolve.GetProjectManager().GetCurrentProject()
    mp = project.GetMediaPool()
    root = mp.GetRootFolder()
    current = mp.GetCurrentFolder()
    main_bin = _get_or_create_bin(mp, root, BIN_NAME)
    rear_bin = _get_or_create_bin(mp, main_bin, REAR_BIN_NAME)
    files = find_insv(paths)
    if not files:
        log("No .insv files found.")
        return []
    results = []
    for i, f in enumerate(files):
        log("[%d/%d] %s" % (i + 1, len(files), os.path.basename(f)))
        info = prepare(f, log=log, accessory=accessory, distance=distance)
        if info["lenses"] < 2:
            log("  warning: only one video track; this camera stores both lenses side by side "
                "(supported via sidecar layout).")
        # lens 1 first so the main clip can reference it
        lens1_item = None
        if info["lens1"]:
            lens1_item = _find_clip_by_path(rear_bin, info["lens1"])
            if lens1_item is None:
                mp.SetCurrentFolder(rear_bin)
                items = mp.ImportMedia([info["lens1"]]) or []
                lens1_item = items[0] if items else None
        main_item = _find_clip_by_path(main_bin, info["lens0"])
        if main_item is None:
            mp.SetCurrentFolder(main_bin)
            items = mp.ImportMedia([info["lens0"]]) or []
            main_item = items[0] if items else None
        if main_item is None:
            log("  ERROR: Resolve could not import %s" % info["lens0"])
            continue
        meta = info.get("meta", {})
        props = {
            "Comments": "%s | insv=%s | sidecar=%s | lens1=%s" % (
                TAG, info["insv"], info["sidecar"], lens1_item.GetMediaId() if lens1_item else ""),
            "Camera Type": meta.get("camera", "Insta360"),
            "Camera Serial #": meta.get("serial", ""),
            "Camera Firmware": meta.get("firmware", ""),
            "Description": "Insta360 360° (%s) - apply 'open360 Reframe' to timeline clips" % (
                meta.get("log") or "standard color"),
        }
        for k, v in props.items():
            if v:
                main_item.SetClipProperty(k, v)
        if lens1_item:
            lens1_item.SetClipProperty("Comments", "%s rear lens of %s" % (TAG, os.path.basename(f)))
            lens1_item.SetClipColor("Brown")
        main_item.SetClipColor("Teal")
        results.append({"item": main_item, "lens1": lens1_item, "info": info})
        log("  imported %s (no transcoding; %s -> %s)" % (main_item.GetName(), info["method"], os.path.basename(f)))
    mp.SetCurrentFolder(current or main_bin)
    return results


def parse_tag(media_item):
    """Return dict(insv, sidecar, lens1) if the media pool item was imported by this tool."""
    if media_item is None:
        return None
    try:
        c = media_item.GetClipProperty("Comments") or ""
    except Exception:
        return None
    if TAG not in c or "sidecar=" not in c:
        return None
    out = {}
    for part in c.split("|"):
        if "=" in part:
            k, v = part.strip().split("=", 1)
            out[k.strip()] = v.strip()
    return out


# ---------------------------------------------------------------------------- Fusion

def _find_tool(comp, reg_id):
    for t in (comp.GetToolList(False) or {}).values():
        if t.GetAttrs()["TOOLS_RegID"] == reg_id:
            return t
    return None


def _tools_by_reg(comp, reg_id):
    return [t for t in (comp.GetToolList(False) or {}).values() if t.GetAttrs()["TOOLS_RegID"] == reg_id]


def setup_comp(comp, tag, stabilize=2, projection=0, force=False, size=None):
    """Insert the open360 pipeline into a timeline clip's Fusion comp. Returns status string."""
    existing = _find_tool(comp, FUSE_ID)
    if existing is not None and not force:
        existing.Sidecar = tag["sidecar"]
        return "already set up"
    media_ins = _tools_by_reg(comp, "MediaIn")
    mi0 = None
    for m in media_ins:
        if m.GetInput("MediaSource") == "Timeline" or m.Name == "MediaIn1":
            mi0 = m
            break
    mo = _find_tool(comp, "MediaOut")
    if mi0 is None or mo is None:
        return "no MediaIn/MediaOut in comp"
    comp.Lock()
    comp.StartUndo("open360 Reframe")
    try:
        if existing is not None:
            existing.Delete()
        for m in media_ins:
            if m is not mi0 and (m.GetInput("MediaID") or "") == tag.get("lens1"):
                m.Delete()
        x, y = 0, 0
        try:
            flow = comp.CurrentFrame.FlowView
            x, y = flow.GetPos(mi0)
        except Exception:
            pass
        mi1 = comp.AddTool("MediaIn", x, y + 2)
        mi1.SetInput("MediaSource", "MediaPool")
        mi1.SetInput("MediaID", tag["lens1"])
        mi1.SetInput("Layer", "0")  # AddTool defaults to the next free layer index
        mi1.SetAttrs({"TOOLS_Name": "open360_RearLens"})
        # keep the rear lens frame-locked to the edited front-lens clip
        mi1.GlobalIn.SetExpression("%s.GlobalIn" % mi0.Name)
        mi1.GlobalOut.SetExpression("%s.GlobalOut" % mi0.Name)
        mi1.ClipTimeStart.SetExpression("%s.ClipTimeStart" % mi0.Name)
        mi1.ClipTimeEnd.SetExpression("%s.ClipTimeEnd" % mi0.Name)
        rf = comp.AddTool(FUSE_ID, x + 2, y + 1)
        if rf is None:
            raise RuntimeError("Open360Reframe Fuse is not installed (restart Resolve after install).")
        rf.SetAttrs({"TOOLS_Name": "Open360Reframe"})
        rf.Sidecar = tag["sidecar"]
        rf.Stabilize = stabilize
        rf.Projection = projection
        rf.FrameOffset.SetExpression("-%s.GlobalIn" % mi0.Name)
        if size:
            # clip comps use the clip's (square) frame format, so pin the timeline size
            rf.UseCompSize = 0
            rf.Width = int(size[0])
            rf.Height = int(size[1])
        rf.Lens0 = mi0.Output
        rf.Lens1 = mi1.Output
        mo.Input = rf.Output
    finally:
        comp.EndUndo(True)
        comp.Unlock()
    return "ok"


def _frames_to_tc(frame, fps):
    fps_i = int(round(fps))
    f = int(frame)
    return "%02d:%02d:%02d:%02d" % (f // (3600 * fps_i), (f // (60 * fps_i)) % 60, (f // fps_i) % 60, f % fps_i)


def _open_item_comp(resolve, tl, item):
    """Make `item`'s Fusion comp the current one on the Fusion page and return it.
    Comps obtained via TimelineItem.GetFusionCompByIndex() while another clip is open in Fusion
    accept edits that are neither rendered nor saved, so we always edit the live comp."""
    fps = float(tl.GetSetting("timelineFrameRate") or 25)
    mid = item.GetStart() + max(0, item.GetDuration() // 2)
    tl.SetCurrentTimecode(_frames_to_tc(mid, fps))
    resolve.OpenPage("fusion")
    fu = resolve.Fusion()
    comp = fu.GetCurrentComp() if fu else None
    if comp is None:
        return None
    mi = comp.FindTool("MediaIn1")
    want = item.GetMediaPoolItem().GetName()
    if mi is not None and mi.GetInput("ClipName") not in (want, None, ""):
        return None
    return comp


def apply_reframe(resolve, items=None, stabilize=2, projection=0, force=False, log=print):
    """Apply to given timeline items, or to every Insta360 clip in the current timeline."""
    project = resolve.GetProjectManager().GetCurrentProject()
    tl = project.GetCurrentTimeline()
    if tl is None:
        log("No current timeline.")
        return 0
    if items is None:
        items = []
        for ti in range(1, tl.GetTrackCount("video") + 1):
            items += tl.GetItemListInTrack("video", ti) or []
    page = resolve.GetCurrentPage()
    tc = tl.GetCurrentTimecode()
    n = 0
    for it in items:
        tag = parse_tag(it.GetMediaPoolItem())
        if not tag or not tag.get("lens1"):
            continue
        if it.GetFusionCompCount() == 0:
            it.AddFusionComp()
        comp = _open_item_comp(resolve, tl, it)
        if comp is None:
            log("  %s: could not open its Fusion comp" % it.GetName())
            continue
        size = (int(tl.GetSetting("timelineResolutionWidth") or 1920),
                int(tl.GetSetting("timelineResolutionHeight") or 1080))
        status = setup_comp(comp, tag, stabilize=stabilize, projection=projection, force=force, size=size)
        log("  %s: %s" % (it.GetName(), status))
        if status in ("ok", "already set up"):
            n += 1
    tl.SetCurrentTimecode(tc)
    if page:
        resolve.OpenPage(page)
    return n
