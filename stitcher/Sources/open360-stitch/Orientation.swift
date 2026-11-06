import Foundation
import simd

enum StabilizeMode: String, CaseIterable {
    /// No stabilization: raw camera orientation.
    case off
    /// Remove shake but keep intentional camera moves (incl. tilt).
    case smooth
    /// Level horizon, heading smoothly follows the camera (Insta360 "FlowState + Horizon Lock").
    case horizon
    /// Level horizon and fixed heading (Insta360 "Direction Lock").
    case lock
}

/// Integrates the IMU into a body->world orientation for every video frame.
/// World frame: +Y up, +Z = initial heading of lens 0, +X right.
struct OrientationTrack {
    private(set) var frameQ: [simd_quatd] = []

    init(imu: [IMUSample], frameTimes: [Double], timeOffset: Double = 0, horizonGain: Double = 2.0) {
        guard imu.count > 10, !frameTimes.isEmpty else {
            frameQ = Array(repeating: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), count: frameTimes.count)
            return
        }
        // Gyro bias from the quietest samples.
        let still = imu.filter { simd_length($0.gyro) < 0.05 }
        var bias = SIMD3<Double>(repeating: 0)
        if still.count > 200 {
            for k in 0..<3 {
                let v = still.map { $0.gyro[k] }.sorted()
                bias[k] = v[v.count / 2]
            }
        }
        // Initial attitude from the average gravity over the first 100 ms.
        var a0 = SIMD3<Double>(repeating: 0)
        let t0 = imu[0].t
        for s in imu where s.t < t0 + 0.1 { a0 += s.acc }
        var q = OrientationTrack.rotation(from: simd_normalize(a0), to: SIMD3(0, 1, 0))
        // Remove any yaw introduced by the leveling so lens 0 initially faces +Z.
        q = OrientationTrack.yaw(-OrientationTrack.heading(q)) * q

        var times = [Double](); times.reserveCapacity(imu.count)
        var qs = [simd_quatd](); qs.reserveCapacity(imu.count)
        times.append(imu[0].t); qs.append(q)
        let up = SIMD3<Double>(0, 1, 0)
        for i in 1..<imu.count {
            let dt = max(0, min(0.01, imu[i].t - imu[i - 1].t))
            let w = imu[i - 1].gyro - bias
            let ang = simd_length(w) * dt
            if ang > 1e-12 { q = q * simd_quatd(angle: ang, axis: simd_normalize(w)) }
            // Complementary tilt correction towards measured gravity.
            let a = imu[i].acc
            let an = simd_length(a)
            if an > 0.75 && an < 1.25 {
                let aw = q.act(a / an)
                let axis = simd_cross(aw, up)
                let s = simd_length(axis)
                if s > 1e-9 {
                    let trust = 1 - min(1, abs(an - 1) / 0.25)
                    let corr = min(asin(min(1, s)), horizonGain * dt * trust)
                    q = simd_quatd(angle: corr, axis: axis / s) * q
                }
            }
            q = simd_normalize(q)
            times.append(imu[i].t); qs.append(q)
        }
        frameQ = frameTimes.map { ft in
            let t = ft + timeOffset
            var lo = 0, hi = times.count - 1
            if t <= times[lo] { return qs[lo] }
            if t >= times[hi] { return qs[hi] }
            while hi - lo > 1 { let m = (lo + hi) / 2; if times[m] <= t { lo = m } else { hi = m } }
            let f = (t - times[lo]) / max(1e-9, times[hi] - times[lo])
            return simd_slerp(qs[lo], qs[hi], f)
        }
    }

    /// Per-frame rotation taking an output-view direction to a camera-body direction.
    func viewToBody(mode: StabilizeMode, smoothSeconds: Double, fps: Double) -> [simd_double3x3] {
        let n = frameQ.count
        guard n > 0 else { return [] }
        let sigma = max(0.5, smoothSeconds * fps)
        var view = [simd_quatd](repeating: simd_quatd(ix: 0, iy: 0, iz: 0, r: 1), count: n)
        switch mode {
        case .off:
            view = frameQ
        case .lock:
            let h0 = OrientationTrack.heading(frameQ[0])
            view = Array(repeating: OrientationTrack.yaw(h0), count: n)
        case .horizon:
            var h = frameQ.map { OrientationTrack.heading($0) }
            for i in 1..<n { // unwrap
                while h[i] - h[i - 1] > .pi { h[i] -= 2 * .pi }
                while h[i] - h[i - 1] < -.pi { h[i] += 2 * .pi }
            }
            let hs = OrientationTrack.gaussian(h, sigma: sigma)
            view = hs.map { OrientationTrack.yaw($0) }
        case .smooth:
            // Gaussian-weighted quaternion average (sign-aligned), fine for small spreads.
            let r = Int(ceil(3 * sigma))
            for i in 0..<n {
                var acc = simd_double4(0, 0, 0, 0)
                let ref = frameQ[i].vector
                for j in max(0, i - r)...min(n - 1, i + r) {
                    let w = exp(-Double((j - i) * (j - i)) / (2 * sigma * sigma))
                    var v = frameQ[j].vector
                    if simd_dot(v, ref) < 0 { v = -v }
                    acc += w * v
                }
                view[i] = simd_normalize(simd_quatd(vector: acc))
            }
        }
        // d_body = R_body^T * R_view * d_view
        return (0..<n).map { i in simd_double3x3(frameQ[i].inverse * view[i]) }
    }

    // MARK: helpers
    static func heading(_ q: simd_quatd) -> Double {
        let f = q.act(SIMD3<Double>(0, 0, 1))
        return atan2(f.x, f.z)
    }
    static func yaw(_ a: Double) -> simd_quatd { simd_quatd(angle: a, axis: SIMD3(0, 1, 0)) }
    static func rotation(from a: SIMD3<Double>, to b: SIMD3<Double>) -> simd_quatd {
        let c = simd_cross(a, b), d = simd_dot(a, b)
        if simd_length(c) < 1e-9 { return d > 0 ? simd_quatd(ix: 0, iy: 0, iz: 0, r: 1) : simd_quatd(angle: .pi, axis: SIMD3(1, 0, 0)) }
        return simd_quatd(angle: atan2(simd_length(c), d), axis: simd_normalize(c))
    }
    static func gaussian(_ x: [Double], sigma: Double) -> [Double] {
        let n = x.count, r = Int(ceil(3 * sigma))
        return (0..<n).map { i in
            var s = 0.0, ws = 0.0
            for j in (i - r)...(i + r) {
                let jj = min(n - 1, max(0, j)) // clamp at edges
                let w = exp(-Double((j - i) * (j - i)) / (2 * sigma * sigma))
                s += w * x[jj]; ws += w
            }
            return s / ws
        }
    }
}
