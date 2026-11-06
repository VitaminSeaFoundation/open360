import Foundation
import Metal
import CoreVideo
import simd

/// How the two fisheye images are laid out in the decoded video.
enum LensLayout {
    /// Two video tracks, one per lens (full-resolution .insv from X5/X6 class cameras).
    case separateTracks
    /// One track, lenses side by side. `swapped` = lens 0 on the right half.
    case sideBySide(swapped: Bool)
}

/// Lens accessories change how angles map to image height. The camera does not record which
/// one was fitted. Profiles are Insta360's θ(deg)→image-height(mm) polynomials as stored in X5
/// trailers (field 145, documented by orbis-reframe); the X6 stores none, so they are used as
/// the best available approximation and refined by the per-clip radius fit.
enum LensAccessory: String, CaseIterable {
    case bare, guardLens = "guard", water = "water", diveWater = "dive-water", diveAir = "dive-air"
    static let bareProfile: [Double] = [0, 0.03159, -8.415e-05, 2.201e-06, -1.284e-08]
    /// Parametric radius profile per lens r0 * (1 + a1 u^2 + a2 u^4), u = theta / 90 deg.
    /// "water": Insta360 X6 water lens, fitted against Insta360 Studio output (see README).
    var radial: [(Double, Double, Double)] {
        switch self {
        case .water: return LensAccessory.waterRadial
        default: return [(1, 0, 0), (1, 0, 0)]
        }
    }
    static var waterRadial: [(Double, Double, Double)] = {
        // developer override: OPEN360_WATER_RADIAL="r0,a1,a2,r0,a1,a2"
        if let e = ProcessInfo.processInfo.environment["OPEN360_WATER_RADIAL"] {
            let v = e.split(separator: ",").compactMap { Double($0) }
            if v.count == 6 { return [(v[0], v[1], v[2]), (v[3], v[4], v[5])] }
        }
        return [(1.0778, -0.0311, -0.0416), (1.0646, -0.0318, 0.0)]
    }()
    var profile: [Double]? {
        switch self {
        case .bare, .water: return nil
        case .guardLens: return [0, 0.0321906505, -9.37245e-05, 2.5248e-06, -1.5e-08]
        case .diveWater: return [0.000238, 0.03112, 7.306e-06, 4.427e-07, -3.892e-09]
        case .diveAir: return [0, 0.0299338566, 4.86874e-05, -6.784e-07, 1.2e-09]
        }
    }
}

struct StitchSettings {
    var accessory = LensAccessory.bare
    /// Extra common image radius scale (1 = profile as is), fitted per clip.
    var radiusScale: (Double, Double) = (1, 1)
    /// Effective per-lens radial model (r0, a1, a2) = accessory profile x radiusScale.
    func radial(_ lens: Int) -> (Double, Double, Double) {
        let r = accessory.radial[lens]
        return (r.0 * (lens == 0 ? radiusScale.0 : radiusScale.1), r.1, r.2)
    }
    var outWidth = 7680
    var outHeight = 3840
    var featherDeg = 3.0
    /// Stitch distance in meters; nil / infinity = calibrated at infinity.
    var distance: Double? = 2.0
    var lens1Gain: Double = 1.0
    /// Sign applied to the lens-1 translation vector (calibration convention).
    var translationSign: Double = 1.0
}

final class Stitcher {
    let device: MTLDevice
    let queue: MTLCommandQueue
    private let lumaPSO: MTLComputePipelineState
    private let chromaPSO: MTLComputePipelineState
    private let probePSO: MTLComputePipelineState
    private var cache: CVMetalTextureCache!
    let lenses: [LensCalibration]
    var layout: LensLayout
    var settings: StitchSettings
    /// Per-lens luma texture size in pixels.
    var lensTexSize = SIMD2<Double>(0, 0)

    init(lenses: [LensCalibration], layout: LensLayout, settings: StitchSettings) throws {
        guard let dev = MTLCreateSystemDefaultDevice(), let q = dev.makeCommandQueue() else {
            throw InsvError.io("No Metal device available")
        }
        device = dev; queue = q
        let lib = try dev.makeLibrary(source: stitchShaderSource, options: nil)
        lumaPSO = try dev.makeComputePipelineState(function: lib.makeFunction(name: "stitchLuma")!)
        chromaPSO = try dev.makeComputePipelineState(function: lib.makeFunction(name: "stitchChroma")!)
        probePSO = try dev.makeComputePipelineState(function: lib.makeFunction(name: "seamProbe")!)
        CVMetalTextureCacheCreate(nil, nil, dev, nil, &cache)
        self.lenses = lenses
        self.layout = layout
        self.settings = settings
    }

    // MARK: parameters

    /// "zxy" = Rz(roll-90) Rx(yaw) Ry(pitch) in the calibration's image axes (orbis-reframe's
    /// measured order); "xyz" = the order first fitted here. Selected per clip by seam error.
    static var rotationOrder = "zxy"
    static var rotationTranspose = false

    static func lensRotation(_ c: LensCalibration) -> simd_double3x3 {
        func rad(_ d: Double) -> Double { d * .pi / 180 }
        let a = rad(c.rotDeg.0), b = rad(c.rotDeg.1), g = rad(c.rotDeg.2 - 90)
        let X = simd_double3x3(rows: [SIMD3(1, 0, 0), SIMD3(0, cos(a), -sin(a)), SIMD3(0, sin(a), cos(a))])
        let Y = simd_double3x3(rows: [SIMD3(cos(b), 0, sin(b)), SIMD3(0, 1, 0), SIMD3(-sin(b), 0, cos(b))])
        let Z = simd_double3x3(rows: [SIMD3(cos(g), -sin(g), 0), SIMD3(sin(g), cos(g), 0), SIMD3(0, 0, 1)])
        let R = rotationOrder == "xyz" ? X * Y * Z : Z * X * Y
        return rotationTranspose ? R.transpose : R
    }

    func packParams(viewToBody M: simd_double3x3, width: Int, height: Int, featherDeg: Double? = nil,
                    distance: Double?? = nil, lens1Gain: Double? = nil) -> [Float] {
        var P = [Float](repeating: 0, count: 160)
        for r in 0..<3 {
            let row = SIMD3(M[0][r], M[1][r], M[2][r]) // simd matrices are column-major
            P[r * 4] = Float(row.x); P[r * 4 + 1] = Float(row.y); P[r * 4 + 2] = Float(row.z)
        }
        P[12] = Float(width); P[13] = Float(height)
        P[14] = Float((featherDeg ?? settings.featherDeg) * .pi / 180)
        let dist = distance ?? settings.distance
        if let d = dist, d.isFinite, d > 0 { P[15] = Float(1 / d) }
        P[17] = Float(lens1Gain ?? settings.lens1Gain)
        P[18] = Float(lensTexSize.x); P[19] = Float(lensTexSize.y)
        for (i, c) in lenses.prefix(2).enumerated() {
            let b = 32 + 48 * i
            let ls = c.lensSize, fw = c.focalWindow
            P[b + 0] = Float(c.xi); P[b + 1] = Float(c.fx / fw); P[b + 2] = Float(c.fy / fw)
            P[b + 3] = Float(c.cx.truncatingRemainder(dividingBy: ls) / ls); P[b + 4] = Float(c.cy / ls)
            P[b + 5] = Float(c.k.0); P[b + 6] = Float(c.k.1); P[b + 7] = Float(c.k.2); P[b + 8] = Float(c.k.3)
            P[b + 9] = Float(c.p.0); P[b + 10] = Float(c.p.1)
            P[b + 11] = Float(c.s.0); P[b + 12] = Float(c.s.1); P[b + 13] = Float(c.s.2); P[b + 14] = Float(c.s.3)
            let sg = settings.translationSign
            P[b + 15] = Float(c.translation.0 * sg); P[b + 16] = Float(c.translation.1 * sg); P[b + 17] = Float(c.translation.2 * sg)
            P[b + 18] = 0.4925
            switch layout {
            case .separateTracks: P[b + 19] = 0; P[b + 20] = 1
            case .sideBySide(let swapped):
                let right = (i == 1) != swapped
                P[b + 19] = right ? 0.5 : 0; P[b + 20] = 0.5
            }
            let rr = settings.radial(i)
            P[b + 21] = Float(rr.0); P[b + 22] = Float(rr.1); P[b + 23] = Float(rr.2)
            let R = Stitcher.lensRotation(c)
            for r in 0..<3 {
                P[b + 24 + r * 4] = Float(R[0][r]); P[b + 25 + r * 4] = Float(R[1][r]); P[b + 26 + r * 4] = Float(R[2][r])
            }
        }
        if let prof = settings.accessory.profile {
            for k in 0..<5 { P[128 + k] = Float(LensAccessory.bareProfile[k]); P[133 + k] = Float(prof[k]) }
            P[138] = 1
        }
        return P
    }

    // MARK: textures

    func texture(_ pb: CVPixelBuffer, plane: Int, format: MTLPixelFormat) -> (MTLTexture, CVMetalTexture)? {
        let w = CVPixelBufferGetWidthOfPlane(pb, plane), h = CVPixelBufferGetHeightOfPlane(pb, plane)
        var cvt: CVMetalTexture?
        let r = CVMetalTextureCacheCreateTextureFromImage(nil, cache, pb, nil, format, w, h, plane, &cvt)
        guard r == kCVReturnSuccess, let t = cvt, let mt = CVMetalTextureGetTexture(t) else { return nil }
        return (mt, t)
    }

    /// Configure per-lens texture size from a decoded input buffer.
    func configure(input pb: CVPixelBuffer) {
        let w = Double(CVPixelBufferGetWidthOfPlane(pb, 0)), h = Double(CVPixelBufferGetHeightOfPlane(pb, 0))
        switch layout {
        case .separateTracks: lensTexSize = SIMD2(w, h)
        case .sideBySide: lensTexSize = SIMD2(w / 2, h)
        }
    }

    /// Stitch one frame. Inputs/outputs are bi-planar YCbCr (16-bit containers, 10-bit data).
    /// `inB` may equal `inA` for side-by-side layouts.
    func stitch(inA: CVPixelBuffer, inB: CVPixelBuffer, out: CVPixelBuffer, viewToBody M: simd_double3x3,
                commandBuffer cb: MTLCommandBuffer) -> [CVMetalTexture] {
        let W = CVPixelBufferGetWidth(out), H = CVPixelBufferGetHeight(out)
        var P = packParams(viewToBody: M, width: W, height: H)
        var keep: [CVMetalTexture] = []
        guard let (ya, k1) = texture(inA, plane: 0, format: .r16Unorm),
              let (ca, k2) = texture(inA, plane: 1, format: .rg16Unorm),
              let (yb, k3) = texture(inB, plane: 0, format: .r16Unorm),
              let (cbT, k4) = texture(inB, plane: 1, format: .rg16Unorm),
              let (oy, k5) = texture(out, plane: 0, format: .r16Unorm),
              let (oc, k6) = texture(out, plane: 1, format: .rg16Unorm) else { return [] }
        keep = [k1, k2, k3, k4, k5, k6]
        guard let enc = cb.makeComputeCommandEncoder() else { return keep }
        enc.setComputePipelineState(lumaPSO)
        enc.setTextures([ya, yb, oy], range: 0..<3)
        enc.setBytes(&P, length: P.count * 4, index: 0)
        dispatch(enc, lumaPSO, oy.width, oy.height)
        enc.setComputePipelineState(chromaPSO)
        enc.setTextures([ca, cbT, oc], range: 0..<3)
        enc.setBytes(&P, length: P.count * 4, index: 0)
        dispatch(enc, chromaPSO, oc.width, oc.height)
        enc.endEncoding()
        return keep
    }

    private func dispatch(_ enc: MTLComputeCommandEncoder, _ pso: MTLComputePipelineState, _ w: Int, _ h: Int) {
        let tw = pso.threadExecutionWidth, th = max(1, pso.maxTotalThreadsPerThreadgroup / tw)
        enc.dispatchThreads(MTLSize(width: w, height: h, depth: 1), threadsPerThreadgroup: MTLSize(width: tw, height: th, depth: 1))
    }

    // MARK: auto calibration helpers

    /// Samples the overlap band of both lenses. Returns (lumaA, lumaB, valid) triples.
    func probeSeam(inA: CVPixelBuffer, inB: CVPixelBuffer, distance: Double?, bandDeg: Double = 4,
                   samples: Int = 2048, rows: Int = 9) -> [(Float, Float)] {
        var P = packParams(viewToBody: matrix_identity_double3x3, width: samples, height: rows,
                           featherDeg: bandDeg, distance: .some(distance), lens1Gain: 1)
        guard let (ya, k1) = texture(inA, plane: 0, format: .r16Unorm),
              let (yb, k2) = texture(inB, plane: 0, format: .r16Unorm),
              let buf = device.makeBuffer(length: samples * rows * 3 * 4, options: .storageModeShared),
              let cb = queue.makeCommandBuffer(), let enc = cb.makeComputeCommandEncoder() else { return [] }
        enc.setComputePipelineState(probePSO)
        enc.setTextures([ya, yb], range: 0..<2)
        enc.setBuffer(buf, offset: 0, index: 1)
        enc.setBytes(&P, length: P.count * 4, index: 0)
        dispatch(enc, probePSO, samples, rows)
        enc.endEncoding()
        cb.commit(); cb.waitUntilCompleted()
        _ = (k1, k2)
        let p = buf.contents().bindMemory(to: Float.self, capacity: samples * rows * 3)
        var out: [(Float, Float)] = []
        for i in 0..<(samples * rows) where p[i * 3 + 2] > 0.5 { out.append((p[i * 3], p[i * 3 + 1])) }
        return out
    }

    /// Mean absolute gradient-free difference in the seam band (lower = better alignment).
    static func seamError(_ s: [(Float, Float)], gain: Float = 1) -> Double {
        guard !s.isEmpty else { return .infinity }
        let blk: Float = 64.0 / 1023.0
        var e: Double = 0
        for (a, b) in s { e += Double(abs(a - (blk + (b - blk) * gain))) }
        return e / Double(s.count)
    }

    /// Exposure gain for lens 1 so that its overlap luma matches lens 0.
    static func gain(_ s: [(Float, Float)]) -> Double {
        let blk: Float = 64.0 / 1023.0
        var sa: Double = 0, sb: Double = 0
        for (a, b) in s { sa += Double(max(0, a - blk)); sb += Double(max(0, b - blk)) }
        guard sb > 1e-6 else { return 1 }
        return min(1.5, max(0.67, sa / sb))
    }
}
