import Foundation

/// Per-lens calibration parsed from the Insta360 "offset" string stored in the .insv trailer.
///
/// Insta360 uses a unified omnidirectional (Mei) camera model:
///   m = (X / (Z + xi*|X|), Y / (Z + xi*|X|))
///   m_d = m * (1 + k1 r^2 + k2 r^4 + k3 r^6 + k4 r^8)
///   pixel = (fx * m_d.x + cx, fy * m_d.y + cy)
/// All pixel quantities are expressed in the calibration frame (calWidth x calHeight),
/// where the lenses sit side by side; lens 1's cx therefore carries a +calHeight offset.
struct LensCalibration {
    var xi: Double
    var fx: Double, fy: Double
    var cx: Double, cy: Double
    var rotDeg: (Double, Double, Double)
    var translation: (Double, Double, Double)
    var k: (Double, Double, Double, Double)
    /// tangential (p1, p2) and thin-prism (s1..s4) terms, OpenCV omnidir form
    var p: (Double, Double) = (0, 0)
    var s: (Double, Double, Double, Double) = (0, 0, 0, 0)
    var calWidth: Double, calHeight: Double
    /// Window the focal lengths refer to (protobuf field 27 dst size; X6: 7680 of 7744).
    var focalRef: Double = 0

    /// Width/height of a single lens image in calibration pixels.
    var lensSize: Double { calHeight }
    var focalWindow: Double { focalRef > 0 ? focalRef : calHeight }
}

struct IMUSample {
    var t: Double          // seconds (camera clock)
    var acc: SIMD3<Double> // camera frame, in g, +Y = up
    var gyro: SIMD3<Double> // camera frame, rad/s
}

struct InsvMetadata {
    var cameraModel: String = "Insta360"
    var serial: String = ""
    var firmware: String = ""
    var logMode: String = ""
    var offsetString: String = ""
    var lenses: [LensCalibration] = []
    var imu: [IMUSample] = []
    /// Camera-clock timestamp (seconds) of every video frame, from the exposure record.
    var frameTimes: [Double] = []
    var exposure: [Double] = []
    /// Rolling-shutter frame readout time in seconds (protobuf field 25).
    var readoutTime: Double = 0
    var cropSrc: Double = 0, cropDst: Double = 0
    var gyroRangeDps: Double = 2000, accRangeG: Double = 32

    var isLog: Bool { logMode.lowercased().contains("log") }
}

enum InsvError: Error, CustomStringConvertible {
    case noTrailer, noCalibration(String), io(String)
    var description: String {
        switch self {
        case .noTrailer: return "File has no Insta360 metadata trailer (not an original .insv/.lrv?)"
        case .noCalibration(let s): return "Could not find/parse lens calibration: \(s)"
        case .io(let s): return s
        }
    }
}

/// IMU axis mapping (camera = M * imu) verified for Insta360 X6 by visual gyro alignment
/// (frame-to-frame registration of stitched frames) and gravity tracking.
/// camera X (right of lens 0)  =  imu Z
/// camera Y (up)               = -imu X
/// camera Z (lens 0 optical)   =  imu Y
struct IMUAxisMap {
    var rows: [(Int, Double)] = [(2, 1), (0, -1), (1, 1)]
    func apply(_ v: SIMD3<Double>) -> SIMD3<Double> {
        SIMD3(v[rows[0].0] * rows[0].1, v[rows[1].0] * rows[1].1, v[rows[2].0] * rows[2].1)
    }
    /// Parse e.g. "z,-x,y"
    init?(spec: String) {
        let parts = spec.lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        guard parts.count == 3 else { return nil }
        var r: [(Int, Double)] = []
        for p in parts {
            let neg = p.hasPrefix("-")
            let axis = p.replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "+", with: "")
            guard let i = ["x", "y", "z"].firstIndex(of: axis) else { return nil }
            r.append((i, neg ? -1 : 1))
        }
        rows = r
    }
    init() {}
}

enum InsvParser {
    static let magic = "8db42d694ccc418790edff439fe026bf"

    static func parse(url: URL, imuMap: IMUAxisMap = IMUAxisMap(), gyroLSB: Double = 16.4, accLSB: Double = 1024) throws -> InsvMetadata {
        guard let fh = try? FileHandle(forReadingFrom: url) else { throw InsvError.io("Cannot open \(url.path)") }
        defer { try? fh.close() }
        let size = try fh.seekToEnd()
        guard size > 72 else { throw InsvError.noTrailer }
        try fh.seek(toOffset: size - 72)
        let tail = fh.readData(ofLength: 72)
        guard String(data: tail.suffix(32), encoding: .ascii) == magic else { throw InsvError.noTrailer }
        let extra = UInt64(tail.u32(at: 32))
        var records: [UInt8: Data] = [:]
        var offs: UInt64 = 72
        while offs < extra && offs + 6 <= size {
            try fh.seek(toOffset: size - offs - 6)
            let h = fh.readData(ofLength: 6)
            let id = h[h.startIndex + 1]
            let len = UInt64(h.u32(at: 2))
            if len > 0, offs + 6 + len <= size {
                try fh.seek(toOffset: size - offs - 6 - len)
                if records[id] == nil { records[id] = fh.readData(ofLength: Int(len)) }
            }
            offs += len + 6
        }
        var md = InsvMetadata()
        if let info = records[1] { parseInfo(info, into: &md); parseProtobuf(info, into: &md) }
        guard !md.offsetString.isEmpty else { throw InsvError.noCalibration("no offset string in trailer") }
        md.lenses = try parseOffset(md.offsetString)
        // focal lengths refer to the crop window; fall back to the model's known window
        var ref = md.cropDst
        if ref <= 0 {
            if md.cameraModel.contains("X6") { ref = 7680 } else if md.cameraModel.contains("X5") { ref = 5312 }
        }
        for i in md.lenses.indices { md.lenses[i].focalRef = ref }

        if let g = records[3] {
            md.imu = parseIMU(g, map: imuMap, gyroLSB: 32768.0 / md.gyroRangeDps, accLSB: 32768.0 / md.accRangeG)
        }
        if let e = records[4], e.count % 16 == 0 {
            let n = e.count / 16
            md.frameTimes.reserveCapacity(n)
            for i in 0..<n {
                md.frameTimes.append(Double(e.u64(at: i * 16)) / 1e6)
                md.exposure.append(e.f64(at: i * 16 + 8))
            }
        }
        return md
    }

    /// Record 1 is a protobuf message. Rather than depending on the (private, camera-specific)
    /// schema we pull out its printable strings and recognise them by shape.
    static func parseInfo(_ d: Data, into md: inout InsvMetadata) {
        var strings: [String] = []
        var cur: [UInt8] = []
        for b in d {
            if b >= 0x20 && b < 0x7f { cur.append(b) } else {
                if cur.count >= 3 { strings.append(String(decoding: cur, as: UTF8.self)) }
                cur.removeAll()
            }
        }
        if cur.count >= 3 { strings.append(String(decoding: cur, as: UTF8.self)) }
        for s in strings {
            if s.hasPrefix("Insta360") { md.cameraModel = s }
            else if s.hasPrefix("v") && s.dropFirst().allSatisfy({ $0.isNumber || $0 == "." }) { md.firmware = s }
            else if s.lowercased().contains("log") && s.count < 16 { md.logMode = s }
            else if s.count > 100 && s.allSatisfy({ $0.isNumber || "._-".contains($0) }) {
                if s.count > md.offsetString.count { md.offsetString = s }
            } else if md.serial.isEmpty && s.count >= 10 && s.count <= 20 && s.allSatisfy({ $0.isUppercase || $0.isNumber }) {
                md.serial = s
            }
        }
    }

    static func parseOffset(_ s: String) throws -> [LensCalibration] {
        let v = s.split(separator: "_").compactMap { Double($0) }
        guard v.count > 1, let n = Int(exactly: v[0]), n == 2 else {
            throw InsvError.noCalibration("unsupported offset format (expected 2 lenses): \(s.prefix(40))…")
        }
        let perLens = (v.count - 1) / n
        guard perLens >= 27 else {
            throw InsvError.noCalibration("unsupported offset format (\(perLens) params per lens). This tool currently supports the X5/X6-generation calibration layout.")
        }
        return (0..<n).map { i in
            let p = Array(v[(1 + i * perLens)..<(1 + (i + 1) * perLens)])
            return LensCalibration(xi: p[0], fx: p[1], fy: p[2], cx: p[3], cy: p[4],
                                   rotDeg: (p[5], p[6], p[7]), translation: (p[8], p[9], p[10]),
                                   k: (p[11], p[12], p[13], p[14]),
                                   p: (p[16], p[17]), s: (p[18], p[19], p[20], p[21]),
                                   calWidth: p[24], calHeight: p[25])
        }
    }

    // Minimal protobuf walk of the metadata record (field numbers per orbis-reframe's notes):
    // 25 rolling-shutter readout (ms, double), 27 window_crop_info {1,2 src; 3,4 dst},
    // 65 gyro_cfg_info {1 acc range g, 2 gyro range dps}.
    static func parseProtobuf(_ d: Data, into md: inout InsvMetadata) {
        func fields(_ b: [UInt8]) -> [(Int, Int, UInt64, [UInt8])] {
            var out: [(Int, Int, UInt64, [UInt8])] = []
            var i = 0
            func varint() -> UInt64? {
                var r: UInt64 = 0, sh: UInt64 = 0
                while i < b.count {
                    let c = b[i]; i += 1
                    r |= UInt64(c & 0x7f) << sh; sh += 7
                    if c < 0x80 { return r }
                    if sh > 63 { return nil }
                }
                return nil
            }
            while i < b.count {
                guard let key = varint() else { break }
                let f = Int(key >> 3), wt = Int(key & 7)
                switch wt {
                case 0: guard let v = varint() else { return out }; out.append((f, wt, v, []))
                case 1: guard i + 8 <= b.count else { return out }
                    var v: UInt64 = 0; for k in 0..<8 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }; i += 8
                    out.append((f, wt, v, []))
                case 5: guard i + 4 <= b.count else { return out }
                    var v: UInt64 = 0; for k in 0..<4 { v |= UInt64(b[i + k]) << (8 * UInt64(k)) }; i += 4
                    out.append((f, wt, v, []))
                case 2: guard let l = varint(), i + Int(l) <= b.count else { return out }
                    out.append((f, wt, 0, Array(b[i..<(i + Int(l))]))); i += Int(l)
                default: return out
                }
            }
            return out
        }
        for (f, wt, v, sub) in fields([UInt8](d)) {
            switch (f, wt) {
            case (25, 1): md.readoutTime = Double(bitPattern: v) / 1000
            case (27, 2):
                for (g, _, x, _) in fields(sub) {
                    if g == 1 { md.cropSrc = Double(x) }
                    if g == 3 { md.cropDst = Double(x) }
                }
            case (65, 2):
                for (g, _, x, _) in fields(sub) {
                    if g == 1, x > 0 { md.accRangeG = Double(x) }
                    if g == 2, x > 0 { md.gyroRangeDps = Double(x) }
                }
            default: break
            }
        }
    }

    static func parseIMU(_ d: Data, map: IMUAxisMap, gyroLSB: Double, accLSB: Double) -> [IMUSample] {
        var out: [IMUSample] = []
        if d.count % 20 == 0 {
            // u64 timestamp (µs) + 6 x u16 offset-binary: acc xyz, gyro xyz
            let n = d.count / 20
            out.reserveCapacity(n)
            for i in 0..<n {
                let b = i * 20
                func c(_ k: Int) -> Double { Double(Int(d.u16(at: b + 8 + 2 * k)) - 32768) }
                let acc = SIMD3(c(0), c(1), c(2)) / accLSB
                let gyr = SIMD3(c(3), c(4), c(5)) / gyroLSB * .pi / 180
                // The gyro's sign convention is opposite to the accelerometer's on X6
                // (verified: integrating -gyro tracks long-term gravity within ~2°).
                out.append(IMUSample(t: Double(d.u64(at: b)) / 1e6, acc: map.apply(acc), gyro: -map.apply(gyr)))
            }
        } else if d.count % 56 == 0 {
            // legacy layout: u64 ms + 6 x f64 (acc in g, gyro in rad/s)
            let n = d.count / 56
            for i in 0..<n {
                let b = i * 56
                let acc = SIMD3(d.f64(at: b + 8), d.f64(at: b + 16), d.f64(at: b + 24))
                let gyr = SIMD3(d.f64(at: b + 32), d.f64(at: b + 40), d.f64(at: b + 48))
                out.append(IMUSample(t: Double(d.u64(at: b)) / 1e3, acc: map.apply(acc), gyro: map.apply(gyr)))
            }
        }
        return out
    }
}

extension Data {
    func u16(at o: Int) -> UInt16 { self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt16.self) }.littleEndian }
    func u32(at o: Int) -> UInt32 { self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt32.self) }.littleEndian }
    func u64(at o: Int) -> UInt64 { self.withUnsafeBytes { $0.loadUnaligned(fromByteOffset: o, as: UInt64.self) }.littleEndian }
    func f64(at o: Int) -> Double { Double(bitPattern: u64(at: o)) }
}
