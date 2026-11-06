import Foundation

/// Injects Google Spherical Video V1 (uuid/XML in trak) and V2 (st3d + sv3d in the visual
/// sample entry) metadata so players / NLEs recognise the file as monoscopic equirectangular 360.
/// The original moov is turned into a `free` box and a rewritten moov is appended, so media
/// offsets (stco/co64) never change.
enum SphericalMetadata {
    struct Box { var type: String; var start: Int; var size: Int; var headerSize: Int }

    static func boxes(_ d: Data, _ range: Range<Int>) -> [Box] {
        var out: [Box] = []
        var o = range.lowerBound
        while o + 8 <= range.upperBound {
            var size = Int(d.be32(o))
            let type = String(decoding: d[(o + 4)..<(o + 8)], as: UTF8.self)
            var hs = 8
            if size == 1 { size = Int(d.be64(o + 8)); hs = 16 }
            else if size == 0 { size = range.upperBound - o }
            guard size >= hs, o + size <= range.upperBound else { break }
            out.append(Box(type: type, start: o, size: size, headerSize: hs))
            o += size
        }
        return out
    }

    static func box(_ type: String, _ payload: Data) -> Data {
        var d = Data(); d.appendBE32(UInt32(8 + payload.count)); d.append(type.data(using: .ascii)!); d.append(payload); return d
    }
    static func fullBox(_ type: String, _ payload: Data) -> Data { box(type, Data([0, 0, 0, 0]) + payload) }

    static func v2Boxes(software: String) -> Data {
        let st3d = fullBox("st3d", Data([0]))
        let svhd = fullBox("svhd", (software.data(using: .utf8) ?? Data()) + Data([0]))
        let prhd = fullBox("prhd", Data(count: 12))
        let equi = fullBox("equi", Data(count: 16))
        let sv3d = box("sv3d", svhd + box("proj", prhd + equi))
        return st3d + sv3d
    }

    static func v1Box(software: String) -> Data {
        let xml = """
        <?xml version="1.0"?><rdf:SphericalVideo xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#" \
        xmlns:GSpherical="http://ns.google.com/videos/1.0/spherical/"><GSpherical:Spherical>true</GSpherical:Spherical>\
        <GSpherical:Stitched>true</GSpherical:Stitched><GSpherical:StitchingSoftware>\(software)</GSpherical:StitchingSoftware>\
        <GSpherical:ProjectionType>equirectangular</GSpherical:ProjectionType></rdf:SphericalVideo>
        """
        let uuid: [UInt8] = [0xff, 0xcc, 0x82, 0x63, 0xf8, 0x55, 0x4a, 0x93, 0x88, 0x14, 0x58, 0x7a, 0x02, 0x52, 0x1f, 0xdd]
        return box("uuid", Data(uuid) + xml.data(using: .utf8)!)
    }

    /// Rebuilds a container box replacing children through `transform`.
    static func rebuild(_ d: Data, _ b: Box, prefix: Int = 0, transform: (Box) -> Data?) -> Data {
        let bodyStart = b.start + b.headerSize + prefix
        var payload = Data(d[(b.start + b.headerSize)..<bodyStart])
        for c in boxes(d, bodyStart..<(b.start + b.size)) {
            payload.append(transform(c) ?? Data(d[c.start..<(c.start + c.size)]))
        }
        return box(b.type, payload)
    }

    static func inject(into url: URL, software: String = "open360-stitch") throws {
        let fh = try FileHandle(forUpdating: url)
        defer { try? fh.close() }
        let fileSize = Int(try fh.seekToEnd())
        // locate top-level moov without reading mdat
        var o = 0
        var moov: Box?
        while o + 8 <= fileSize {
            try fh.seek(toOffset: UInt64(o))
            let h = fh.readData(ofLength: 16)
            var size = Int(h.be32(0)); var hs = 8
            let type = String(decoding: h[4..<8], as: UTF8.self)
            if size == 1 { size = Int(h.be64(8)); hs = 16 } else if size == 0 { size = fileSize - o }
            if type == "moov" { moov = Box(type: type, start: o, size: size, headerSize: hs); break }
            guard size >= 8 else { break }
            o += size
        }
        guard let m = moov else { throw InsvError.io("moov not found") }
        try fh.seek(toOffset: UInt64(m.start))
        let md = fh.readData(ofLength: m.size)
        let local = Box(type: "moov", start: 0, size: m.size, headerSize: m.headerSize)

        var injected = false
        let newMoov = rebuild(md, local) { trak in
            guard trak.type == "trak", isVideoTrak(md, trak) else { return nil }
            var t = rebuild(md, trak) { mdia in
                guard mdia.type == "mdia" else { return nil }
                return rebuild(md, mdia) { minf in
                    guard minf.type == "minf" else { return nil }
                    return rebuild(md, minf) { stbl in
                        guard stbl.type == "stbl" else { return nil }
                        return rebuild(md, stbl) { stsd in
                            guard stsd.type == "stsd" else { return nil }
                            // stsd: fullbox(4) + entry_count(4), then sample entries
                            return rebuild(md, stsd, prefix: 8) { entry in
                                // VisualSampleEntry has 78 bytes of fixed fields after the header
                                let fixed = 78
                                var e = Data(md[(entry.start + entry.headerSize)..<(entry.start + entry.headerSize + fixed)])
                                for c in boxes(md, (entry.start + entry.headerSize + fixed)..<(entry.start + entry.size))
                                where c.type != "st3d" && c.type != "sv3d" {
                                    e.append(md[c.start..<(c.start + c.size)])
                                }
                                e.append(v2Boxes(software: software))
                                injected = true
                                return box(entry.type, e)
                            }
                        }
                    }
                }
            }
            // V1: append uuid box at the end of trak
            t.append(v1Box(software: software))
            t.replaceSubrange(0..<4, with: be32(UInt32(t.count)))
            return t
        }
        guard injected else { throw InsvError.io("no video sample entry found for spherical metadata") }
        // neutralise old moov, append new one
        try fh.seek(toOffset: UInt64(m.start + 4))
        fh.write("free".data(using: .ascii)!)
        try fh.seekToEnd()
        fh.write(newMoov)
    }

    static func isVideoTrak(_ d: Data, _ trak: Box) -> Bool {
        for mdia in boxes(d, (trak.start + trak.headerSize)..<(trak.start + trak.size)) where mdia.type == "mdia" {
            for h in boxes(d, (mdia.start + mdia.headerSize)..<(mdia.start + mdia.size)) where h.type == "hdlr" {
                let t = String(decoding: d[(h.start + 16)..<(h.start + 20)], as: UTF8.self)
                return t == "vide"
            }
        }
        return false
    }

    static func be32(_ v: UInt32) -> Data { var d = Data(); d.appendBE32(v); return d }
}

extension Data {
    func be32(_ o: Int) -> UInt32 { let b = self.startIndex + o; return UInt32(self[b]) << 24 | UInt32(self[b + 1]) << 16 | UInt32(self[b + 2]) << 8 | UInt32(self[b + 3]) }
    func be64(_ o: Int) -> UInt64 { UInt64(be32(o)) << 32 | UInt64(be32(o + 4)) }
    mutating func appendBE32(_ v: UInt32) { append(contentsOf: [UInt8(v >> 24), UInt8((v >> 16) & 0xff), UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]) }
}
