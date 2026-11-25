import Foundation
import UIKit
import CoreMedia
import VideoToolbox
import CoreVideo
import CoreImage

/// Decodes the board's H.264 Annex-B access units with VideoToolbox and
/// exposes the latest frame for display and analysis.
final class VideoPipe {
    private let reassembler = Reassembler()
    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var sps = Data(), pps = Data()
    private(set) var latestPixelBuffer: CVPixelBuffer?
    private var latestAt = Date.distantPast
    var onNewFrame: (() -> Void)?
    let ciContext = CIContext()

    func feed(_ chunk: Data, gap: Bool) {
        if gap { reassembler.lost() }
        if let au = reassembler.feed(chunk) { handle(au) }
    }

    private func handle(_ au: AU) {
        let nals = Self.nals(au.data)
        var haveNewParams = false
        for (type, body) in nals {
            if type == 7 && body != sps { sps = body; haveNewParams = true }
            if type == 8 && body != pps { pps = body; haveNewParams = true }
        }
        if haveNewParams, !sps.isEmpty, !pps.isEmpty, let f = Self.format(sps: sps, pps: pps) {
            format = f
            session = nil   // rebuilt lazily
        }
        guard format != nil else { return }
        if session == nil {
            guard let f = format else { return }
            var raw: VTDecompressionSession?
            let refcon = Unmanaged.passUnretained(self).toOpaque()
            let cb: VTDecompressionOutputCallback = { refcon, _, status, _, buffer, _, _ in
                guard status == noErr, let buf = buffer, let ref = refcon else { return }
                let pipe = Unmanaged<VideoPipe>.fromOpaque(ref).takeUnretainedValue()
                pipe.sink(pixelBuffer: buf)
            }
            var record = VTDecompressionOutputCallbackRecord(decompressionOutputCallback: cb,
                                                             decompressionOutputRefCon: refcon)
            let attrs: [CFString: Any] = [kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_32BGRA]
            let st = VTDecompressionSessionCreate(allocator: kCFAllocatorDefault,
                                                  formatDescription: f,
                                                  decoderSpecification: nil,
                                                  imageBufferAttributes: attrs as CFDictionary,
                                                  outputCallback: &record,
                                                  decompressionSessionOut: &raw)
            guard st == noErr, let s = raw else { return }
            session = s
        }
        decode(au.data)
    }

    private func sink(pixelBuffer: CVPixelBuffer) {
        latestPixelBuffer = pixelBuffer
        latestAt = Date()
        onNewFrame?()
    }

    private func decode(_ annexB: Data) {
        guard let session, let format else { return }
        let prefixed = Self.lengthPrefixed(annexB)
        guard !prefixed.isEmpty else { return }
        var bb: CMBlockBuffer?
        guard CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                 blockLength: prefixed.count, blockAllocator: nil,
                                                 customBlockSource: nil, offsetToData: 0,
                                                 dataLength: prefixed.count, flags: 0,
                                                 blockBufferOut: &bb) == kCMBlockBufferNoErr,
              let block = bb else { return }
        prefixed.withUnsafeBytes {
            _ = CMBlockBufferReplaceDataBytes(with: $0.baseAddress!, blockBuffer: block,
                                              offsetIntoDestination: 0, dataLength: prefixed.count)
        }
        var timing = CMSampleTimingInfo(duration: CMTime.invalid,
                                        presentationTimeStamp: CMTime(value: 0, timescale: 1000),
                                        decodeTimeStamp: CMTime.invalid)
        var sb: CMSampleBuffer?
        let st = CMSampleBufferCreateReady(allocator: kCFAllocatorDefault, dataBuffer: block,
                                           formatDescription: format, sampleCount: 1,
                                           sampleTimingEntryCount: 1, sampleTimingArray: &timing,
                                           sampleSizeEntryCount: 1, sampleSizeArray: [prefixed.count],
                                           sampleBufferOut: &sb)
        guard st == noErr, let sample = sb else { return }
        let flags: VTDecodeFrameFlags = []
        var info = VTDecodeInfoFlags()
        VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags,
                                          frameRefcon: nil, infoFlagsOut: &info)
    }

    /// Latest frame converted to a UIImage for display (throttle at the caller).
    func uiImage() -> UIImage? {
        guard let pb = latestPixelBuffer else { return nil }
        let ci = CIImage(cvPixelBuffer: pb)
        guard let cg = ciContext.createCGImage(ci, from: ci.extent) else { return nil }
        return UIImage(cgImage: cg)
    }

    /// Downscaled grayscale snapshot for diffing / quick math.
    func graySnapshot(width: Int = 320) -> (w: Int, h: Int, data: [UInt8])? {
        guard let pb = latestPixelBuffer,
              Date().timeIntervalSince(latestAt) < 2.0 else { return nil }
        CVPixelBufferLockBaseAddress(pb, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pb, .readOnly) }
        let w = CVPixelBufferGetWidth(pb), h = CVPixelBufferGetHeight(pb)
        guard let base = CVPixelBufferGetBaseAddress(pb) else { return nil }
        let stride = CVPixelBufferGetBytesPerRow(pb)
        let hh = max(1, width * h / w)
        var out = [UInt8](repeating: 0, count: width * hh)
        let ptr = base.assumingMemoryBound(to: UInt8.self)
        for y in 0..<hh {
            let sy = y * h / hh
            for x in 0..<width {
                let sx = x * w / width
                let o = sy * stride + sx * 4
                let b = ptr[o], g = ptr[o+1], r = ptr[o+2]
                out[y * width + x] = UInt8((r * 299 + g * 587 + b * 114) >> 10)
            }
        }
        return (width, hh, out)
    }

    var isFresh: Bool { Date().timeIntervalSince(latestAt) < 2.0 }

    // MARK: NAL helpers

    static func nals(_ data: Data) -> [(type: UInt8, body: Data)] {
        var result: [(UInt8, Data)] = []
        var i = 0
        let d = [UInt8](data)
        var starts: [Int] = []
        while i + 3 < d.count {
            if d[i] == 0 && d[i+1] == 0 && d[i+2] == 1 { starts.append(i + 3); i += 3; continue }
            if i + 4 <= d.count && d[i] == 0 && d[i+1] == 0 && d[i+2] == 0 && d[i+3] == 1 {
                starts.append(i + 4); i += 4; continue
            }
            i += 1
        }
        for (n, s) in starts.enumerated() {
            let e = n + 1 < starts.count ? starts[n + 1] - 3 : d.count
            let end = min(e, d.count)
            if s > d.count || end <= s { continue }
            var body = Array(d[s..<end])
            // strip trailing start-code zeros of the next NAL
            while let last = body.last, last == 0 { body.removeLast() }
            guard let t = body.first else { continue }
            result.append((t & 0x1F, Data(body.dropFirst())))
        }
        return result
    }

    /// Annex-B (00 00 01 NAL) → 4-byte-length-prefixed NALs, as the avcC format expects.
    static func lengthPrefixed(_ data: Data) -> Data {
        var out = Data()
        for (_, body) in nals(data) {
            var len = UInt32(body.count).bigEndian
            withUnsafeBytes(of: &len) { out += Data($0) }
            out += body
        }
        return out
    }

    static func format(sps: Data, pps: Data) -> CMVideoFormatDescription? {
        var avcc = Data([0x01, sps.count > 2 ? sps[1] : 0, sps.count > 3 ? sps[2] : 0, sps.count > 4 ? sps[3] : 0, 0xFF, 0xE1])
        var l = UInt16(sps.count).bigEndian
        withUnsafeBytes(of: &l) { avcc += Data($0) }
        avcc += sps
        avcc.append(1)
        l = UInt16(pps.count).bigEndian
        withUnsafeBytes(of: &l) { avcc += Data($0) }
        avcc += pps
        let atom: [String: Any] = ["atomType": "avcC", "atomData": avcc]
        let extensions: [String: Any] = ["SampleDescriptionExtensionAtoms": [atom]]
        var fmt: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: kCFAllocatorDefault, codecType: kCMVideoCodecType_H264,
                                       width: 0, height: 0, extensions: extensions as CFDictionary,
                                       formatDescriptionOut: &fmt)
        return fmt
    }
}
