#!/usr/bin/env python3
"""
open360 for DaVinci Resolve  (Workspace > Scripts > open360)

 * Import .insv  - brings camera-original Insta360 clips into the media pool WITHOUT transcoding
                   (zero-copy lens files + gyro/calibration analysis, ~2 s per clip)
 * Reframe       - sets up the Fusion comp of Insta360 clips on the current timeline:
                   both lenses -> "open360 Reframe" (stitch + stabilize + reframe on the GPU)
"""
import os
import sys
import traceback

HERE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "open360") if "__file__" in globals() else None
for cand in [HERE,
             os.path.expanduser("~/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/open360"),
             "/Library/Application Support/Blackmagic Design/DaVinci Resolve/Fusion/Scripts/Utility/open360"]:
    if cand and os.path.isdir(cand) and cand not in sys.path:
        sys.path.insert(0, cand)

import open360_resolve as ir  # noqa: E402


def get_resolve():
    g = globals()
    if g.get("resolve"):
        return g["resolve"]
    if g.get("app"):
        try:
            return g["app"].GetResolve()
        except Exception:
            pass
    try:
        return bmd.scriptapp("Resolve")  # noqa: F821
    except Exception:
        pass
    import DaVinciResolveScript as dvr
    return dvr.scriptapp("Resolve")


resolve = get_resolve()
fusion = resolve.Fusion()
ui = fusion.UIManager
disp = bmd.UIDispatcher(ui)  # noqa: F821

STAB = ["Off (raw camera)", "Smooth (keep camera moves)", "Horizon Lock (FlowState)", "Direction Lock"]

win = disp.AddWindow({
    "ID": "Open360Win", "WindowTitle": "open360 - Insta360 .insv tools", "Geometry": [200, 200, 660, 600],
}, ui.VGroup([
    ui.Label({"Text": "<b>Import Insta360 .insv</b> &nbsp; (no transcoding — the camera originals are read directly)",
              "WordWrap": True}),
    ui.HGroup([
        ui.Button({"ID": "ImportFiles", "Text": "Import .insv Files…"}),
        ui.Button({"ID": "ImportFolder", "Text": "Import Folder…"}),
    ]),
    ui.HGroup([
        ui.Label({"Text": "Lens accessory", "Weight": 0}),
        ui.ComboBox({"ID": "Acc"}),
        ui.Label({"Text": "Stitch distance (m)", "Weight": 0}),
        ui.LineEdit({"ID": "Dist", "Text": "1", "MaximumSize": [60, 30]}),
    ]),
    ui.Label({"Text": "The camera does not record lens guards / water lenses: pick the one you shot with "
                      "(like Insta360 Studio). Can be changed later per clip in the Fusion inspector.",
              "WordWrap": True, "StyleSheet": "color: #999"}),
    ui.CheckBox({"ID": "MakeTimeline", "Text": "Create a timeline with the imported clips and set up reframing",
                 "Checked": True}),
    ui.VGap(8),
    ui.Label({"Text": "<b>Reframe</b> &nbsp; (sets up the Fusion comp of every Insta360 clip in the current timeline)",
              "WordWrap": True}),
    ui.HGroup([
        ui.Label({"Text": "Stabilization", "Weight": 0}),
        ui.ComboBox({"ID": "Stab"}),
        ui.Label({"Text": "Output", "Weight": 0}),
        ui.ComboBox({"ID": "Proj"}),
    ]),
    ui.HGroup([
        ui.Button({"ID": "Apply", "Text": "Apply to Current Timeline"}),
        ui.Button({"ID": "Reapply", "Text": "Rebuild (reset settings)"}),
    ]),
    ui.Label({"Text": "Keyframe Pan / Tilt / Roll / FOV in the Fusion page inspector (tool “Open360Reframe”).",
              "WordWrap": True, "StyleSheet": "color: #999"}),
    ui.TextEdit({"ID": "Log", "ReadOnly": True, "Weight": 1}),
    ui.HGroup([ui.HGap(), ui.Button({"ID": "Close", "Text": "Close"})]),
]))
items = win.GetItems()
for s in STAB:
    items["Stab"].AddItem(s)
items["Stab"].CurrentIndex = 2
for _, label in ir.ACCESSORIES:
    items["Acc"].AddItem(label)
for s in ["Reframe (flat view)", "360 Equirectangular"]:
    items["Proj"].AddItem(s)


def log(msg):
    items["Log"].Append(str(msg))
    print(msg)


def do_import(paths):
    if not paths:
        return
    try:
        acc = ir.ACCESSORIES[items["Acc"].CurrentIndex][0]
        dist = items["Dist"].Text.strip() or "1"
        res = ir.import_insv(resolve, paths, log=log, accessory=acc, distance=dist)
        if res and items["MakeTimeline"].Checked:
            project = resolve.GetProjectManager().GetCurrentProject()
            mp = project.GetMediaPool()
            # match the timeline frame rate to the footage when the project has no timelines yet
            if project.GetTimelineCount() == 0:
                fps = res[0]["info"].get("meta", {}).get("fps")
                if fps:
                    project.SetSetting("timelineFrameRate", str(int(round(fps))) if abs(fps - round(fps)) < 1e-3 else str(fps))
            name = "360 %s" % os.path.splitext(os.path.basename(res[0]["info"]["insv"]))[0]
            tl = mp.CreateTimelineFromClips(name, [r["item"] for r in res])
            if tl:
                project.SetCurrentTimeline(tl)
                n = ir.apply_reframe(resolve, stabilize=items["Stab"].CurrentIndex,
                                     projection=items["Proj"].CurrentIndex, log=log)
                log("Timeline '%s' created, %d clip(s) reframed." % (name, n))
        log("Done.")
    except Exception as e:
        log("ERROR: %s" % e)
        log(traceback.format_exc())


def on_import_files(ev):
    sel = fusion.RequestFile("", "", {"FReqB_Multiple": True, "FReqS_Filter": "Insta360 video (*.insv)|*.insv",
                                      "FReqS_Title": "Choose Insta360 .insv clips"})
    if not sel:
        return
    paths = list(sel.values()) if isinstance(sel, dict) else [sel]
    do_import(paths)


def on_import_folder(ev):
    d = fusion.RequestDir("", {"FReqS_Title": "Choose a folder with .insv clips (searched recursively)"})
    if d:
        do_import([d])


def on_apply(ev, force=False):
    try:
        n = ir.apply_reframe(resolve, stabilize=items["Stab"].CurrentIndex,
                             projection=items["Proj"].CurrentIndex, force=force, log=log)
        log("%d Insta360 clip(s) set up." % n if n else
            "No Insta360 clips found in the current timeline (import them with this tool first).")
    except Exception as e:
        log("ERROR: %s" % e)
        log(traceback.format_exc())


def on_close(ev):
    disp.ExitLoop()


win.On.ImportFiles.Clicked = on_import_files
win.On.ImportFolder.Clicked = on_import_folder
win.On.Apply.Clicked = lambda ev: on_apply(ev, False)
win.On.Reapply.Clicked = lambda ev: on_apply(ev, True)
win.On.Close.Clicked = on_close
win.On.Open360Win.Close = on_close

try:
    ir.find_helper()
except Exception as e:
    log("WARNING: %s" % e)
win.Show()
disp.RunLoop()
win.Hide()
