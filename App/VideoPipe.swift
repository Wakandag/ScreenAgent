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
    /// Chunks received from the board, for diagnostics.
    private(set) var chunks = 0
    var onLog: ((String) -> Void)?
    private var aus = 0
    /// Frames handed to the screen, for diagnostics/resync.
    private(set) var frames = 0
    let ciContext = CIContext()

    func feed(_ chunk: Data, gap: Bool) {
        chunks += 1
        if gap { reassembler.lost() }
        if let au = reassembler.feed(chunk) { handle(au) }
    }

    private func handle(_ au: AU) {
        aus += 1
        if aus <= 3 || aus % 30 == 0 {
            onLog?("video: AU #\(aus) \(au.data.count)B flags=\(au.flags)")
        }
        let nals = Self.nals(au.data)
        var haveNewParams = false
        for (type, body) in nals {
            if type == 7 && body != sps { sps = body; haveNewParams = true }
            if type == 8 && body != pps { pps = body; haveNewParams = true }
        }
        if haveNewParams {
            if !sps.isEmpty, !pps.isEmpty, let f = Self.format(sps: sps, pps: pps) {
                format = f
                session = nil   // rebuilt lazily
                onLog?("video: format ok (\(sps.count)B SPS, \(pps.count)B PPS)")
            } else {
                onLog?("video: format build failed")
            }
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
            guard st == noErr, let s = raw else {
                onLog?("video: decoder create failed \(st)")
                return
            }
            session = s
        }
        decode(au.data)
    }

    private func sink(pixelBuffer: CVPixelBuffer) {
        frames += 1
        latestPixelBuffer = pixelBuffer
        latestAt = Date()
        onNewFrame?()
    }

    private func decode(_ annexB: Data) {
        guard let session, let format else { return }
        let prefixed = Self.lengthPrefixed(annexB)
        guard !prefixed.isEmpty else { return }
        var bb: CMBlockBuffer?
        // memoryBlock is NULL here, so the block buffer needs its own allocator.
        let bbStatus = CMBlockBufferCreateWithMemoryBlock(allocator: kCFAllocatorDefault, memoryBlock: nil,
                                                          blockLength: prefixed.count,
                                                          blockAllocator: kCFAllocatorDefault,
                                                          customBlockSource: nil, offsetToData: 0,
                                                          dataLength: prefixed.count, flags: 0,
                                                          blockBufferOut: &bb)
        guard bbStatus == kCMBlockBufferNoErr, let block = bb else {
            onLog?("video: block buffer failed \(bbStatus)")
            return
        }
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
        let dst = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: flags,
                                                    frameRefcon: nil, infoFlagsOut: &info)
        if dst != noErr { onLog?("video: decode failed \(dst)") }
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
                let b = Int(ptr[o]), g = Int(ptr[o+1]), r = Int(ptr[o+2])
                out[y * width + x] = UInt8((r * 299 + g * 587 + b * 114) >> 10)
            }
        }
        return (width, hh, out)
    }

    var isFresh: Bool { Date().timeIntervalSince(latestAt) < 2.0 }

    // MARK: NAL helpers

    static func nals(_ data: Data) -> [(type: UInt8, body: Data)] {
        let d = [UInt8](data)
        // Start-code positions, with the length of each code so a NAL always ends
        // exactly where the next code begins (3-byte codes end with a zero byte
        // that belongs to the code, not to the NAL). Trailing payload zeros are
        // real PPS/SPS bytes, so they must not be stripped.
        var starts: [(body: Int, codeLen: Int)] = []
        var i = 0
        while i + 3 <= d.count {
            if d[i] == 0 && d[i+1] == 0 && d[i+2] == 1 { starts.append((i + 3, 3)); i += 3; continue }
            if i + 4 <= d.count && d[i] == 0 && d[i+1] == 0 && d[i+2] == 0 && d[i+3] == 1 {
                starts.append((i + 4, 4)); i += 4; continue
            }
            i += 1
        }
        var result: [(UInt8, Data)] = []
        for (n, s) in starts.enumerated() {
            let start = s.body
            let end = n + 1 < starts.count ? starts[n + 1].body - starts[n + 1].codeLen : d.count
            guard start < end, end <= d.count else { continue }
            let body = Data(d[start..<end])
            guard let t = body.first else { continue }
            result.append((t & 0x1F, body.dropFirst()))
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
        var fmt: CMVideoFormatDescription?
        let status: OSStatus = sps.withUnsafeBytes { sraw in
            pps.withUnsafeBytes { praw in
                guard let sp = sraw.bindMemory(to: UInt8.self).baseAddress,
                      let pp = praw.bindMemory(to: UInt8.self).baseAddress else {
                    return OSStatus(-1)
                }
                let sets: [UnsafePointer<UInt8>] = [sp, pp]
                return CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: kCFAllocatorDefault, parameterSetCount: 2,
                    parameterSetPointers: sets, parameterSetSizes: [sps.count, pps.count],
                    nalUnitHeaderLength: 4, formatDescriptionOut: &fmt)
            }
        }
        return status == noErr ? fmt : nil
    }
}
