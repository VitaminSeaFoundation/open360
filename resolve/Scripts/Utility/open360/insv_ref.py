"""
Zero-copy access to Insta360 .insv files for DaVinci Resolve.

Resolve refuses the .insv extension and only decodes the *first* video track of a file, while
X5/X6-class .insv files store each fisheye lens in its own HEVC track. Resolve also ignores
external data references, so "reference movies" do not work. Instead:

  lens 0  ->  a symlink "<name>.mp4" pointing at the camera original (Resolve reads track 1)
  lens 1  ->  an APFS *clone* of the original whose movie header lists only the lens-1 track.
              The clone shares every media block with the original (no extra disk space, no
              copy time); only a few KB of header appended at its end differ. The camera
              original is never modified.

On volumes without clone support (exFAT SD cards, network shares) the lens-1 file falls back
to a regular file copy - still bit-exact, no transcoding - unless allow_copy=False.
"""
import ctypes
import ctypes.util
import os
import shutil
import struct

__all__ = ["make_lens_files", "list_tracks", "clone_supported"]


def _boxes(d, start, end):
    o = start
    while o + 8 <= end:
        size, typ = struct.unpack(">I4s", d[o:o + 8])
        hs = 8
        if size == 1:
            size = struct.unpack(">Q", d[o + 8:o + 16])[0]
            hs = 16
        elif size == 0:
            size = end - o
        if size < hs or o + size > end:
            break
        yield typ.decode("latin1"), o, size, hs
        o += size


def _box(typ, payload):
    return struct.pack(">I4s", 8 + len(payload), typ.encode("latin1")) + payload


def _top_boxes(path):
    sz = os.path.getsize(path)
    out = []
    with open(path, "rb") as f:
        o = 0
        while o + 8 <= sz:
            f.seek(o)
            h = f.read(16)
            size, typ = struct.unpack(">I4s", h[:8])
            hs = 8
            if size == 1:
                size = struct.unpack(">Q", h[8:16])[0]
                hs = 16
            elif size == 0:
                size = sz - o
            out.append((typ.decode("latin1"), o, size, hs))
            if size < 8:
                break
            o += size
    return out


def _read_moov(path):
    for typ, o, size, hs in _top_boxes(path):
        if typ == "moov":
            with open(path, "rb") as f:
                f.seek(o)
                return o, f.read(size)
    raise ValueError("no moov box in %s" % path)


def _handler(d, trak):
    _, o, size, hs = trak
    for t, mo, ms, mh in _boxes(d, o + hs, o + size):
        if t == "mdia":
            for t2, ho, hsz, hh in _boxes(d, mo + mh, mo + ms):
                if t2 == "hdlr":
                    return d[ho + hh + 8:ho + hh + 12].decode("latin1")
    return None


def _set_track_id(d, trak, new_id):
    """Return trak bytes with tkhd track_ID replaced and the track enabled."""
    typ, o, size, hs = trak
    t = bytearray(d[o:o + size])
    for c, co, cs, ch in _boxes(d, o + hs, o + size):
        if c == "tkhd":
            rel = co - o
            ver = t[rel + ch]
            id_off = rel + ch + 4 + (16 if ver == 1 else 8)
            struct.pack_into(">I", t, id_off, new_id)
            t[rel + ch + 3] |= 0x03
    return bytes(t)


def list_tracks(path):
    _, moov = _read_moov(path)
    top = next(_boxes(moov, 0, len(moov)))
    traks = [b for b in _boxes(moov, top[3], len(moov)) if b[0] == "trak"]
    return [(i, _handler(moov, t)) for i, t in enumerate(traks)]


def _moov_for_track(moov, video_index, include_audio):
    top = next(_boxes(moov, 0, len(moov)))
    children = list(_boxes(moov, top[3], len(moov)))
    traks = [b for b in children if b[0] == "trak"]
    video = [t for t in traks if _handler(moov, t) == "vide"]
    audio = [t for t in traks if _handler(moov, t) == "soun"]
    body = b""
    for c in children:
        if c[0] == "trak":
            continue
        if c[0] == "mvhd":
            mv = bytearray(moov[c[1]:c[1] + c[2]])
            struct.pack_into(">I", mv, len(mv) - 4, 16)  # next_track_ID
            body += bytes(mv)
        else:
            body += moov[c[1]:c[1] + c[2]]
    body += _set_track_id(moov, video[video_index], 1)
    tid = 2
    if include_audio:
        for a in audio:
            body += _set_track_id(moov, a, tid)
            tid += 1
    return _box("moov", body), len(video)


# --- APFS clonefile -----------------------------------------------------------------------

_libc = None


def _clonefile(src, dst):
    global _libc
    if _libc is None:
        _libc = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True)
        _libc.clonefile.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint32]
    r = _libc.clonefile(src.encode(), dst.encode(), 0)
    if r != 0:
        e = ctypes.get_errno()
        raise OSError(e, os.strerror(e))


def clone_supported(src, dst_dir):
    probe = os.path.join(dst_dir, ".clone_probe")
    try:
        if os.path.exists(probe):
            os.remove(probe)
        _clonefile(src, probe)
        os.remove(probe)
        return True
    except OSError:
        return False


def _is_current(dst, src, marker):
    """dst was produced from this exact src (size+mtime recorded in an xattr-free marker file)."""
    try:
        with open(marker) as f:
            return f.read().strip() == "%d:%d" % (os.path.getsize(src), int(os.path.getmtime(src))) and os.path.exists(dst)
    except OSError:
        return False


def make_lens_files(insv_path, out_dir, base_name=None, allow_copy=True, log=None):
    """Create Resolve-readable files for each lens. Returns (paths, method) in lens order."""
    insv_path = os.path.abspath(insv_path)
    base_name = base_name or os.path.splitext(os.path.basename(insv_path))[0]
    os.makedirs(out_dir, exist_ok=True)
    moov_off, moov = _read_moov(insv_path)
    paths = []

    # lens 0: symlink (Resolve decodes the first video track + audio of the original)
    p0 = os.path.join(out_dir, base_name + ".mp4")
    if os.path.islink(p0) or os.path.exists(p0):
        if not (os.path.islink(p0) and os.path.realpath(p0) == os.path.realpath(insv_path)):
            os.remove(p0)
    if not os.path.exists(p0):
        os.symlink(insv_path, p0)
    paths.append(p0)

    _, nvideo = _moov_for_track(moov, 0, True)
    method = "symlink"
    for vi in range(1, nvideo):
        method = "apfs-clone (cached)"
        p = os.path.join(out_dir, "%s_lens%d.mp4" % (base_name, vi))
        marker = p + ".src"
        if _is_current(p, insv_path, marker):
            paths.append(p)
            continue
        tmp = p + ".tmp"
        if os.path.exists(tmp):
            os.remove(tmp)
        try:
            _clonefile(insv_path, tmp)
            method = "apfs-clone"
        except OSError as e:
            if not allow_copy:
                raise RuntimeError("Volume does not support APFS clones (%s); copy the footage to an "
                                   "APFS drive or allow copying." % e)
            if log:
                log("  volume has no clone support - copying lens %d (bit-exact, no transcode)" % vi)
            shutil.copyfile(insv_path, tmp)
            method = "copy"
        new_moov, _ = _moov_for_track(moov, vi, False)
        with open(tmp, "r+b") as f:
            if len(new_moov) + 8 <= len(moov):
                # Overwrite the original moov in place (the single-track header is smaller) and
                # pad with a free box: the box layout stays identical to the camera original,
                # which Resolve's parser requires (it does not look past the 'inst' trailer).
                pad = len(moov) - len(new_moov)
                f.seek(moov_off)
                f.write(new_moov + struct.pack(">I4s", pad, b"free") + b"\0" * (pad - 8))
            else:
                f.seek(moov_off + 4)
                f.write(b"free")
                f.seek(0, 2)
                f.write(new_moov)
        os.replace(tmp, p)
        with open(marker, "w") as f:
            f.write("%d:%d" % (os.path.getsize(insv_path), int(os.path.getmtime(insv_path))))
        paths.append(p)
    return paths, method


if __name__ == "__main__":
    import sys
    for a in sys.argv[1:]:
        print(list_tracks(a))
        print(make_lens_files(a, os.path.join(os.path.dirname(os.path.abspath(a)), "open360_links")))
