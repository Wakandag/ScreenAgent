import Foundation
import Vision

/// Free, built-in screen understanding: face/head boxes and OCR.
final class VisionAnalyzer {
    /// Largest face center, normalized (x, y with 0 = top), plus its size relative to screen width.
    func faceCenter(_ pb: CVPixelBuffer) async -> (x: Double, y: Double, size: Double)? {
        let request = VNDetectFaceRectanglesRequest()
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        do { try handler.perform([request]) } catch { return nil }
        guard let faces = (request.results as? [VNFaceObservation]), !faces.isEmpty else { return nil }
        let best = faces.max { $0.boundingBox.width < $1.boundingBox.width }!
        let b = best.boundingBox
        return (Double(b.midX), Double(1 - b.midY), Double(b.width))
    }

    /// OCR the screen, lines with rough positions, capped so an LLM prompt stays small.
    func ocr(_ pb: CVPixelBuffer, maxChars: Int = 1200) async -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .fast
        request.usesLanguageCorrection = false
        let handler = VNImageRequestHandler(cvPixelBuffer: pb, orientation: .up)
        do { try handler.perform([request]) } catch { return "" }
        guard let obs = request.results else { return "" }
        var lines: [(Double, String)] = []
        for o in obs {
            if let top = o.topCandidates(1).first {
                let y = 1.0 - Double(o.boundingBox.midY)
                lines.append((y, top.string))
            }
        }
        lines.sort { $0.0 < $1.0 }
        var text = ""
        for (_, l) in lines {
            let piece = l + "\n"
            if text.count + piece.count > maxChars { text += "[...]"; break }
            text += piece
        }
        return text
    }
}

/// Cursor finding by frame differencing (port of the CLI's pointer "measure" wiggle).
enum FrameDiff {
    static func locate(before: (w: Int, h: Int, data: [UInt8]),
                       after: (w: Int, h: Int, data: [UInt8])) -> (x: Double, y: Double)? {
        guard before.w == after.w, before.h == after.h, before.data.count == after.data.count else { return nil }
        var sx = 0, sy = 0, n = 0
        for y in 0..<before.h {
            for x in 0..<before.w {
                let i = y * before.w + x
                let d = abs(Int(before.data[i]) - Int(after.data[i]))
                if d > 14 {
                    sx += x; sy += y; n += 1
                }
            }
        }
        guard n >= 6, n <= 4000 else { return nil }   // tiny (cursor) but not a scene change
        return (Double(sx) / Double(n) / Double(before.w),
                Double(sy) / Double(n) / Double(before.h))
    }
}
