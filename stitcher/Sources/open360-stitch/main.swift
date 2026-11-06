import Foundation
import AVFoundation
import CoreVideo
import Metal
import simd

// MARK: - CLI

struct Options {
    var input = ""
    var output = ""
    var codec = "prores422"
    var width = 0
    var stabilize = StabilizeMode.horizon
    var smoothSeconds = 1.0
    var distance = "1"
    var feather = 3.0
    var gainMatch = true
    var proxy = ""
    var proxyWidth = 1920
    var proxyCodec = "proresproxy"
    var maxFrames = Int.max
    var start = 0.0
    var duration = 0.0
    var bitrateMbps = 0.0
    var infoOnly = false
    var analyze = ""
    var accessory = "bare"
    var radiusScale: Double? = nil
    var tSign: Double? = 1
    var fitRadius = false
    var quiet = false
    var yawOffset = 0.0
    var imuMap = IMUAxisMap()
    var spherical = true
    var overwrite = false
}

let usage = """
open360-stitch — stitch Insta360 .insv dual-fisheye video to equirectangular 360 for DaVinci Resolve

USAGE: open360-stitch <input.insv> [options]

  -o, --output <file.mov>    Output file (default: <input>_360.mov next to the input)
  --codec <c>                prores422hq | prores422 (default) | proreslt | proresproxy | prores4444 | hevc
  --width <px>               Output width (height = width/2). Default: 2 x lens resolution (7680 for X6)
  --bitrate <Mbps>           HEVC bitrate (default scales with resolution, ~240 Mbps @ 8K)
  --stabilize <m>            off | smooth | horizon (default) | lock
                               smooth  = remove shake, keep camera moves
                               horizon = level horizon + smoothly following heading (FlowState-like)
                               lock    = level horizon + fixed heading (direction lock)
  --smooth <sec>             Smoothing time constant for heading/smooth modes (default 1.0)
  --yaw <deg>                Rotate the output heading (default 0 = lens 0 centered)
  --distance <m|auto|inf>    Stitch distance in meters (default 1). The parallax correction is applied
                             only near the seam. "auto" estimates it from the seam (experimental)
  --feather <deg>            Seam blend width (default 3)
  --accessory <a>            bare (default) | water | guard | dive-water | dive-air | auto
                             The camera does not record lens accessories, so choose the one fitted:
                             water = Insta360 X6 water lens (measured against Insta360 Studio),
                             guard / dive-* = Insta360's X5 profiles, auto = guess from the seam
  --radius-scale <s>         Extra lens image radius scale (default 1)
  --fit-radius               Fit the radius scale from the seam (experimental)
  --translation-sign <1|-1>  Lens-1 baseline convention (default 1, verified on X6)
  --no-gain-match            Disable lens-to-lens exposure matching
  --imu-map <x,y,z>          IMU->camera axis map (default z,-x,y, measured on X6)
  --proxy <file.mov>         Also write a low-res proxy (ProRes Proxy) for Resolve proxy linking
  --proxy-width <px>         Proxy width (default 1920)
  --start <sec>              Start time within the clip
  --duration <sec>           Duration to render
  --frames <n>               Render at most n frames
  --no-spherical-metadata    Do not inject Google spherical (sv3d/uuid) metadata
  -y, --overwrite            Overwrite existing outputs
  --info                     Print clip metadata as JSON and exit
  --analyze <sidecar.lua>    No rendering: estimate stitch parameters, integrate the gyro for every
                             stabilization mode and write a sidecar for the open360 Reframe Fuse
  -q, --quiet                Only print machine-readable progress lines
"""

func parseArgs() -> Options {
    var o = Options()
    var a = Array(CommandLine.arguments.dropFirst())
    func next() -> String {
        guard !a.isEmpty else { fail("missing value for option") }
        return a.removeFirst()
    }
    while !a.isEmpty {
        let s = a.removeFirst()
        switch s {
        case "-h", "--help": print(usage); exit(0)
        case "-o", "--output": o.output = next()
        case "--codec": o.codec = next().lowercased()
        case "--width": o.width = Int(next()) ?? 0
        case "--bitrate": o.bitrateMbps = Double(next()) ?? 0
        case "--stabilize":
            guard let m = StabilizeMode(rawValue: next().lowercased()) else { fail("bad --stabilize value") }
            o.stabilize = m
        case "--smooth": o.smoothSeconds = Double(next()) ?? 1
        case "--yaw": o.yawOffset = Double(next()) ?? 0
        case "--distance": o.distance = next().lowercased()
        case "--feather": o.feather = Double(next()) ?? 3
        case "--no-gain-match": o.gainMatch = false
        case "--proxy": o.proxy = next()
        case "--proxy-width": o.proxyWidth = Int(next()) ?? 1920
        case "--start": o.start = Double(next()) ?? 0
        case "--duration": o.duration = Double(next()) ?? 0
        case "--frames": o.maxFrames = Int(next()) ?? .max
        case "--imu-map": guard let m = IMUAxisMap(spec: next()) else { fail("bad --imu-map") }; o.imuMap = m
        case "--no-spherical-metadata": o.spherical = false
        case "-y", "--overwrite": o.overwrite = true
        case "--info": o.infoOnly = true
        case "--analyze": o.analyze = next()
        case "--accessory": o.accessory = next().lowercased()
        case "--radius-scale": o.radiusScale = Double(next())
        case "--translation-sign": o.tSign = Double(next())
        case "--fit-radius": o.fitRadius = true
        case "-q", "--quiet": o.quiet = true
        default:
            if s.hasPrefix("-") { fail("unknown option \(s)\n\n\(usage)") }
            o.input = s
        }
    }
    if o.input.isEmpty { print(usage); exit(1) }
    return o
}

func fail(_ msg: String) -> Never {
    FileHandle.standardError.write(("ERROR: " + msg + "\n").data(using: .utf8)!)
    exit(1)
}

var quiet = false
func log(_ s: String) { if !quiet { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) } }

// MARK: - Helpers

/// AVFoundation refuses some unknown extensions; expose the file through a .mp4 symlink.
func avCompatibleURL(_ url: URL) throws -> URL {
    let ext = url.pathExtension.lowercased()
    if ["mp4", "mov", "m4v"].contains(ext) { return url }
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("open360-stitch-\(getpid())")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let link = dir.appendingPathComponent(url.deletingPathExtension().lastPathComponent + ".mp4")
    try? FileManager.default.removeItem(at: link)
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: url)
    return link
}

let inputPixelFormat = kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange

func readerOutputSettings() -> [String: Any] {
    [kCVPixelBufferPixelFormatTypeKey as String: inputPixelFormat,
     kCVPixelBufferMetalCompatibilityKey as String: true,
     kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any]]
}

struct CodecSpec {
    var type: AVVideoCodecType
    var pixelFormat: OSType
    var isProRes: Bool
}

func codecSpec(_ name: String) -> CodecSpec {
    switch name {
    case "prores422hq", "hq": return CodecSpec(type: .proRes422HQ, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, isProRes: true)
    case "prores422", "prores": return CodecSpec(type: .proRes422, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, isProRes: true)
    case "proreslt", "lt": return CodecSpec(type: .proRes422LT, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, isProRes: true)
    case "proresproxy", "proxy": return CodecSpec(type: .proRes422Proxy, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, isProRes: true)
    case "prores4444", "4444": return CodecSpec(type: .proRes4444, pixelFormat: kCVPixelFormatType_422YpCbCr10BiPlanarVideoRange, isProRes: true)
    case "hevc", "h265": return CodecSpec(type: .hevc, pixelFormat: kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, isProRes: false)
    default: fail("unknown codec \(name)")
    }
}

final class VideoSink {
    let writer: AVAssetWriter
    let input: AVAssetWriterInput
    let adaptor: AVAssetWriterInputPixelBufferAdaptor
    let width: Int, height: Int

    init(url: URL, width: Int, height: Int, codec: CodecSpec, bitrateMbps: Double, fps: Double, withAudioFrom audioTracks: [AVAssetTrack]) throws {
        self.width = width; self.height = height
        writer = try AVAssetWriter(outputURL: url, fileType: .mov)
        var settings: [String: Any] = [
            AVVideoCodecKey: codec.type,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height,
            AVVideoColorPropertiesKey: [
                AVVideoColorPrimariesKey: AVVideoColorPrimaries_ITU_R_709_2,
                AVVideoTransferFunctionKey: AVVideoTransferFunction_ITU_R_709_2,
                AVVideoYCbCrMatrixKey: AVVideoYCbCrMatrix_ITU_R_709_2,
            ],
        ]
        if !codec.isProRes {
            let px = Double(width * height)
            let mbps = bitrateMbps > 0 ? bitrateMbps : max(20, 240 * px / (7680.0 * 3840.0) * fps / 50.0 * 1.0)
            settings[AVVideoCompressionPropertiesKey] = [
                AVVideoAverageBitRateKey: Int(mbps * 1_000_000),
                AVVideoProfileLevelKey: "HEVC_Main10_AutoLevel",
                AVVideoExpectedSourceFrameRateKey: fps,
            ] as [String: Any]
        }
        input = AVAssetWriterInput(mediaType: .video, outputSettings: settings)
        input.expectsMediaDataInRealTime = false
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: codec.pixelFormat,
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferMetalCompatibilityKey as String: true,
            kCVPixelBufferIOSurfacePropertiesKey as String: [:] as [String: Any],
        ])
        guard writer.canAdd(input) else { throw InsvError.io("writer cannot add video input for \(codec.type.rawValue) \(width)x\(height)") }
        writer.add(input)
        for (i, _) in audioTracks.enumerated() {
            let hint = i < audioFormatHints.count ? audioFormatHints[i] : nil
            let ai = AVAssetWriterInput(mediaType: .audio, outputSettings: nil, sourceFormatHint: hint)
            ai.expectsMediaDataInRealTime = false
            if writer.canAdd(ai) { writer.add(ai); audioInputs.append(ai) }
        }
    }
    var audioInputs: [AVAssetWriterInput] = []

    func makeBuffer() -> CVPixelBuffer? {
        var pb: CVPixelBuffer?
        if let pool = adaptor.pixelBufferPool { CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pb) }
        return pb
    }
}

// MARK: - Main

let opts = parseArgs()
quiet = opts.quiet
let inURL = URL(fileURLWithPath: opts.input).standardizedFileURL
guard FileManager.default.fileExists(atPath: inURL.path) else { fail("input not found: \(inURL.path)") }

let meta: InsvMetadata
do { meta = try InsvParser.parse(url: inURL, imuMap: opts.imuMap) } catch { fail("\(error)") }

let asset = AVURLAsset(url: try avCompatibleURL(inURL))
let sem = DispatchSemaphore(value: 0)
var videoTracks: [AVAssetTrack] = [], audioTracks: [AVAssetTrack] = []
var audioFormatHints: [CMFormatDescription?] = []
var assetDuration = CMTime.zero
Task {
    do {
        videoTracks = try await asset.loadTracks(withMediaType: .video)
        audioTracks = try await asset.loadTracks(withMediaType: .audio)
        for t in audioTracks { audioFormatHints.append(try await t.load(.formatDescriptions).first) }
        assetDuration = try await asset.load(.duration)
    } catch { fail("cannot open video: \(error)") }
    sem.signal()
}
sem.wait()
guard !videoTracks.isEmpty else { fail("no video tracks") }
var fps = 30.0, trackSize = CGSize.zero
do {
    let s2 = DispatchSemaphore(value: 0)
    Task {
        do {
            fps = Double(try await videoTracks[0].load(.nominalFrameRate))
            trackSize = try await videoTracks[0].load(.naturalSize)
        } catch { fail("cannot read video track properties: \(error)") }
        s2.signal()
    }
    s2.wait()
}
let separate = videoTracks.count >= 2

if opts.infoOnly {
    let info: [String: Any] = [
        "camera": meta.cameraModel, "serial": meta.serial, "firmware": meta.firmware,
        "log": meta.logMode, "isLog": meta.isLog,
        "videoTracks": videoTracks.count, "lensWidth": separate ? Int(trackSize.width) : Int(trackSize.width / 2),
        "trackWidth": Int(trackSize.width), "trackHeight": Int(trackSize.height),
        "fps": fps, "duration": assetDuration.seconds, "frames": meta.frameTimes.count,
        "imuSamples": meta.imu.count, "hasGyro": !meta.imu.isEmpty,
        "defaultOutputWidth": separate ? Int(trackSize.width) * 2 : Int(trackSize.width),
    ]
    let d = try JSONSerialization.data(withJSONObject: info, options: [.prettyPrinted, .sortedKeys])
    print(String(data: d, encoding: .utf8)!)
    exit(0)
}

log("\(meta.cameraModel) \(meta.firmware)  \(meta.logMode.isEmpty ? "" : "[\(meta.logMode)]")  \(Int(trackSize.width))x\(Int(trackSize.height)) x\(videoTracks.count) @ \(fps) fps, \(String(format: "%.2f", assetDuration.seconds)) s")

let lensW = separate ? Int(trackSize.width) : Int(trackSize.width) / 2
var outW = opts.width > 0 ? opts.width : lensW * 2
outW = (outW / 4) * 4
let outH = outW / 2
let outURL = opts.output.isEmpty
    ? inURL.deletingLastPathComponent().appendingPathComponent(inURL.deletingPathExtension().lastPathComponent + "_360.mov")
    : URL(fileURLWithPath: opts.output).standardizedFileURL
let proxyURL: URL? = opts.proxy.isEmpty ? nil : URL(fileURLWithPath: opts.proxy).standardizedFileURL
for u in [outURL, proxyURL].compactMap({ $0 }) where opts.analyze.isEmpty && FileManager.default.fileExists(atPath: u.path) {
    if opts.overwrite { try? FileManager.default.removeItem(at: u) } else { fail("output exists (use -y): \(u.path)") }
}

// time range
let startT = CMTime(seconds: opts.start, preferredTimescale: 600)
let durT = opts.duration > 0 ? CMTime(seconds: opts.duration, preferredTimescale: 600) : CMTimeSubtract(assetDuration, startT)
let timeRange = CMTimeRange(start: startT, duration: durT)

var settings = StitchSettings()
settings.outWidth = outW; settings.outHeight = outH; settings.featherDeg = opts.feather
let stitcher: Stitcher
do { stitcher = try Stitcher(lenses: meta.lenses, layout: separate ? .separateTracks : .sideBySide(swapped: false), settings: settings) }
catch { fail("Metal init failed: \(error)") }

// MARK: auto calibration on probe frames

func decodeFrames(at times: [Double]) -> [(CVPixelBuffer, CVPixelBuffer)] {
    var out: [(CVPixelBuffer, CVPixelBuffer)] = []
    for t in times {
        guard let r = try? AVAssetReader(asset: asset) else { continue }
        r.timeRange = CMTimeRange(start: CMTime(seconds: t, preferredTimescale: 600), duration: CMTime(seconds: 0.5, preferredTimescale: 600))
        let oa = AVAssetReaderTrackOutput(track: videoTracks[0], outputSettings: readerOutputSettings())
        r.add(oa)
        var ob: AVAssetReaderTrackOutput?
        if separate { let o = AVAssetReaderTrackOutput(track: videoTracks[1], outputSettings: readerOutputSettings()); r.add(o); ob = o }
        guard r.startReading(), let sa = oa.copyNextSampleBuffer(), let pa = CMSampleBufferGetImageBuffer(sa) else { continue }
        if let ob = ob {
            guard let sb = ob.copyNextSampleBuffer(), let pb = CMSampleBufferGetImageBuffer(sb) else { continue }
            out.append((pa, pb))
        } else { out.append((pa, pa)) }
        r.cancelReading()
    }
    return out
}

let probeTimes = (0..<5).map { opts.start + (durT.seconds) * (0.1 + 0.2 * Double($0)) }
let probes = decodeFrames(at: probeTimes)
if let first = probes.first { stitcher.configure(input: first.0) }

func probeError(distance: Double?, sign: Double, gainMatch: Bool) -> (Double, Double) {
    stitcher.settings.translationSign = sign
    var all: [(Float, Float)] = []
    for (a, b) in probes { all += stitcher.probeSeam(inA: a, inB: b, distance: distance) }
    let g = gainMatch ? Stitcher.gain(all) : 1
    return (Stitcher.seamError(all, gain: Float(g)), g)
}

if !probes.isEmpty {
    if !separate {
        // decide which half holds lens 0
        stitcher.layout = .sideBySide(swapped: false)
        let e0 = probeError(distance: 2, sign: 1, gainMatch: true).0
        stitcher.layout = .sideBySide(swapped: true)
        let e1 = probeError(distance: 2, sign: 1, gainMatch: true).0
        stitcher.layout = .sideBySide(swapped: e1 < e0)
        log("side-by-side layout: lens 0 on the \(e1 < e0 ? "right" : "left") (seam err \(String(format: "%.4f / %.4f", e0, e1)))")
    }
    // 1) lens rotation convention (tiny angles, but measurable on the seam)
    var bestRot = ("zxy", false), bestRotE = Double.infinity
    for order in ["zxy", "xyz"] {
        for tr in [false, true] {
            Stitcher.rotationOrder = order; Stitcher.rotationTranspose = tr
            let e = probeError(distance: nil, sign: 1, gainMatch: true).0
            if e < bestRotE { bestRotE = e; bestRot = (order, tr) }
        }
    }
    Stitcher.rotationOrder = bestRot.0; Stitcher.rotationTranspose = bestRot.1

    // 2) accessory profile + common radius scale + stitch distance (coordinate descent)
    let distances: [Double?] = [nil, 10, 5, 3, 2, 1.5, 1.0, 0.7, 0.5, 0.35, 0.25, 0.18]
    let fixedDistance: Double?? = {
        switch opts.distance {
        case "auto": return nil
        case "inf", "infinity": return .some(nil)
        default:
            guard let d = Double(opts.distance), d > 0 else { fail("bad --distance") }
            return .some(d)
        }
    }()
    let accessories: [LensAccessory] = opts.accessory == "auto" ? LensAccessory.allCases
        : [LensAccessory(rawValue: opts.accessory) ?? { fail("bad --accessory") }()]
    var best = (acc: LensAccessory.bare, scale: 1.0, dist: Optional<Double>(2.0), sign: 1.0, err: Double.infinity, gain: 1.0)
    for acc in accessories {
        stitcher.settings.accessory = acc
        var cur = (scale: opts.radiusScale ?? 1.0, dist: Optional<Double>(2.0), sign: 1.0, err: Double.infinity, gain: 1.0)
        for _ in 0..<2 {
            // distance + sign
            let dl: [Double?] = fixedDistance.map { [$0] } ?? distances
            for d in dl {
                for sg in (d == nil ? [1.0] : (opts.tSign.map { [$0] } ?? [1.0, -1.0])) {
                    stitcher.settings.radiusScale = (cur.scale, cur.scale)
                    let (e, g) = probeError(distance: d, sign: sg, gainMatch: opts.gainMatch)
                    if e < cur.err { cur.err = e; cur.dist = d; cur.sign = sg; cur.gain = g }
                }
            }
            // radius scale
            if opts.radiusScale == nil && opts.fitRadius {
                for sc in stride(from: 0.94, through: 1.06, by: 0.0025) {
                    stitcher.settings.radiusScale = (sc, sc)
                    let (e, g) = probeError(distance: cur.dist, sign: cur.sign, gainMatch: opts.gainMatch)
                    if e < cur.err { cur.err = e; cur.scale = sc; cur.gain = g }
                }
            }
        }
        log(String(format: "  accessory %-10@ radius x%.4f  distance %@  seam err %.4f", acc.rawValue as NSString, cur.scale,
                   (cur.dist.map { String(format: "%.2f m", $0) } ?? "inf") as NSString, cur.err))
        if cur.err < best.err { best = (acc, cur.scale, cur.dist, cur.sign, cur.err, cur.gain) }
    }
    stitcher.settings.accessory = best.acc
    stitcher.settings.radiusScale = (best.scale, best.scale)
    stitcher.settings.distance = best.dist
    stitcher.settings.translationSign = best.sign
    stitcher.settings.lens1Gain = opts.gainMatch ? best.gain : 1
    log("lens rotation: \(bestRot.0)\(bestRot.1 ? " (transposed)" : "")  accessory: \(best.acc.rawValue)  radius x\(String(format: "%.4f", best.scale))")
    log("stitch distance: \(best.dist.map { String(format: "%.2f m", $0) } ?? "infinity") (lens-1 offset sign \(best.sign > 0 ? "+" : "-"))  lens gain: \(String(format: "%.3f", stitcher.settings.lens1Gain))  seam err: \(String(format: "%.4f", best.err))")
}

// MARK: stabilization

let nFramesMeta = meta.frameTimes.count
var viewToBody: [simd_double3x3] = []
var stabMode = opts.stabilize
if meta.imu.isEmpty || nFramesMeta == 0 {
    if stabMode != .off { log("no gyro / frame timing data — stabilization disabled") }
    stabMode = .off
}
if stabMode != .off {
    let track = OrientationTrack(imu: meta.imu, frameTimes: meta.frameTimes)
    viewToBody = track.viewToBody(mode: stabMode, smoothSeconds: opts.smoothSeconds, fps: fps)
}
log("stabilization: \(stabMode.rawValue)")

if !opts.analyze.isEmpty {
    var modes: [String: [simd_double3x3]] = [:]
    if !meta.imu.isEmpty && nFramesMeta > 0 {
        let track = OrientationTrack(imu: meta.imu, frameTimes: meta.frameTimes)
        for m in StabilizeMode.allCases { modes[m.rawValue] = track.viewToBody(mode: m, smoothSeconds: opts.smoothSeconds, fps: fps) }
    }
    do {
        try Sidecar.write(to: URL(fileURLWithPath: opts.analyze), meta: meta, stitcher: stitcher, fps: fps,
                          frames: max(nFramesMeta, Int((assetDuration.seconds * fps).rounded())), modes: modes,
                          source: inURL.path, separate: separate)
    } catch { fail("cannot write sidecar: \(error)") }
    print("SIDECAR \(opts.analyze)")
    exit(0)
}
let yawM = simd_double3x3(simd_quatd(angle: opts.yawOffset * .pi / 180, axis: SIMD3(0, 1, 0)))

// MARK: render

let codec = codecSpec(opts.codec)
let sink: VideoSink, proxySink: VideoSink?
do {
    sink = try VideoSink(url: outURL, width: outW, height: outH, codec: codec, bitrateMbps: opts.bitrateMbps, fps: fps, withAudioFrom: audioTracks)
    if let pu = proxyURL {
        let pw = (opts.proxyWidth / 4) * 4
        proxySink = try VideoSink(url: pu, width: pw, height: pw / 2, codec: codecSpec(opts.proxyCodec), bitrateMbps: 0, fps: fps, withAudioFrom: audioTracks)
    } else { proxySink = nil }
} catch { fail("\(error)") }

let reader: AVAssetReader
do { reader = try AVAssetReader(asset: asset) } catch { fail("\(error)") }
reader.timeRange = timeRange
let outA = AVAssetReaderTrackOutput(track: videoTracks[0], outputSettings: readerOutputSettings())
outA.alwaysCopiesSampleData = false
reader.add(outA)
var outB: AVAssetReaderTrackOutput?
if separate {
    let o = AVAssetReaderTrackOutput(track: videoTracks[1], outputSettings: readerOutputSettings())
    o.alwaysCopiesSampleData = false
    reader.add(o); outB = o
}
// audio comes from independent readers (one per sink) so video decode never stalls on it
func audioReader() -> (AVAssetReader, [AVAssetReaderTrackOutput])? {
    guard !audioTracks.isEmpty, let r = try? AVAssetReader(asset: asset) else { return nil }
    r.timeRange = timeRange
    let outs = audioTracks.map { AVAssetReaderTrackOutput(track: $0, outputSettings: nil) }
    outs.forEach { r.add($0) }
    return r.startReading() ? (r, outs) : nil
}

guard reader.startReading() else { fail("cannot start reading: \(String(describing: reader.error))") }
let sinks = [sink] + (proxySink.map { [$0] } ?? [])
for s in sinks {
    guard s.writer.startWriting() else { fail("cannot start writing: \(String(describing: s.writer.error))") }
    s.writer.startSession(atSourceTime: startT)
}

let group = DispatchGroup()
let expectedFrames = min(opts.maxFrames, Int((durT.seconds * fps).rounded()))
let t0 = Date()
var frameIndex = 0
var lastPTS = startT

// audio pumps
var audioReaders: [AVAssetReader] = []
for s in sinks {
    guard let (ar, outs) = audioReader() else { continue }
    audioReaders.append(ar)
    for (i, ai) in s.audioInputs.enumerated() where i < outs.count {
        group.enter()
        let q = DispatchQueue(label: "audio.\(i)")
        let o = outs[i]
        var done = false
        ai.requestMediaDataWhenReady(on: q) {
            while ai.isReadyForMoreMediaData && !done {
                if let sb = o.copyNextSampleBuffer() {
                    // stop audio when the video frame limit cut the render short
                    if opts.maxFrames != .max, CMSampleBufferGetPresentationTimeStamp(sb) > CMTimeAdd(startT, CMTime(seconds: Double(expectedFrames) / fps, preferredTimescale: 600)) {
                        done = true; ai.markAsFinished(); group.leave(); break
                    }
                    ai.append(sb)
                } else { done = true; ai.markAsFinished(); group.leave() }
            }
        }
    }
}

// video pump
group.enter()
let vq = DispatchQueue(label: "video")
var videoDone = false
func finishVideo() {
    if videoDone { return }
    videoDone = true
    sinks.forEach { $0.input.markAsFinished() }
    group.leave()
}
// first frame index within the metadata timeline (for stabilization lookup)
let startFrame = Int((opts.start * fps).rounded())

sink.input.requestMediaDataWhenReady(on: vq) {
    autoreleasepool {
        while sink.input.isReadyForMoreMediaData && (proxySink?.input.isReadyForMoreMediaData ?? true) && !videoDone {
            guard frameIndex < opts.maxFrames,
                  let sa = outA.copyNextSampleBuffer(), let pa = CMSampleBufferGetImageBuffer(sa) else { finishVideo(); return }
            var pb = pa
            if let ob = outB {
                guard let sb = ob.copyNextSampleBuffer(), let p = CMSampleBufferGetImageBuffer(sb) else { finishVideo(); return }
                pb = p
            }
            let pts = CMSampleBufferGetPresentationTimeStamp(sa)
            if frameIndex == 0 { stitcher.configure(input: pa) }
            // frame index from PTS so we stay in sync with the exposure/gyro timeline
            let fi = Int((pts.seconds * fps).rounded())
            var M = matrix_identity_double3x3
            if !viewToBody.isEmpty { M = viewToBody[max(0, min(viewToBody.count - 1, fi))] }
            M = M * yawM
            guard let cb = stitcher.queue.makeCommandBuffer() else { finishVideo(); return }
            var keep: [CVMetalTexture] = []
            var outs: [(VideoSink, CVPixelBuffer)] = []
            for s in sinks {
                guard let ob = s.makeBuffer() else { fail("no output pixel buffer") }
                keep += stitcher.stitch(inA: pa, inB: pb, out: ob, viewToBody: M, commandBuffer: cb)
                outs.append((s, ob))
            }
            cb.commit(); cb.waitUntilCompleted()
            _ = keep
            for (s, ob) in outs where !s.adaptor.append(ob, withPresentationTime: pts) {
                fail("append failed: \(String(describing: s.writer.error))")
            }
            lastPTS = pts
            frameIndex += 1
            if frameIndex % 10 == 0 || frameIndex == expectedFrames {
                let el = Date().timeIntervalSince(t0)
                let p = min(1, Double(frameIndex) / Double(max(1, expectedFrames)))
                print(String(format: "PROGRESS %.4f frame %d/%d %.1f fps", p, frameIndex, expectedFrames, Double(frameIndex) / max(el, 0.001)))
                fflush(stdout)
            }
        }
    }
}
_ = startFrame

group.wait()
let fin = DispatchGroup()
for s in sinks {
    fin.enter()
    s.writer.finishWriting { fin.leave() }
}
fin.wait()
for s in sinks where s.writer.status != .completed {
    fail("writing failed: \(String(describing: s.writer.error))")
}
if opts.spherical {
    for u in [outURL, proxyURL].compactMap({ $0 }) {
        do { try SphericalMetadata.inject(into: u, software: "open360-stitch (\(meta.cameraModel))") }
        catch { log("warning: spherical metadata injection failed: \(error)") }
    }
}
let el = Date().timeIntervalSince(t0)
log(String(format: "done: %d frames in %.1f s (%.1f fps) -> %@", frameIndex, el, Double(frameIndex) / el, outURL.path))
print("OUTPUT \(outURL.path)")
if let pu = proxyURL { print("PROXY \(pu.path)") }
