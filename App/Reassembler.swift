import Foundation

/// Port of cli/internal/video/reassembler.go: rebuilds H.264 access units
/// from the board's video chunks [seq u16 LE][flags][payload].
struct AU {
    var flags: UInt8
    var ts: UInt32
    var data: Data
}

enum ChunkFlags {
    static let start: UInt8 = 1
    static let end: UInt8 = 2
    static let idr: UInt8 = 4
    static let config: UInt8 = 8
    static let bench: UInt8 = 16
    static let snap: UInt8 = 32
}

final class Reassembler {
    private var expect: Int = -1
    private var cur: AU?
    private var waiting = true
    private(set) var gaps = 0

    func lost() {
        gaps += 1
        cur = nil
        waiting = true
    }

    func feed(_ chunk: Data) -> AU? {
        guard chunk.count >= 3 else { return nil }
        let seq = Int(chunk[0]) | (Int(chunk[1]) << 8)
        let flags = chunk[2]
        let payload = chunk.dropFirst(3)
        if expect >= 0 && seq != expect { lost() }
        expect = (seq + 1) & 0xFFFF
        if flags & ChunkFlags.bench != 0 { return nil }
        if flags & ChunkFlags.start != 0 {
            if (waiting && flags & (ChunkFlags.config | ChunkFlags.idr) == 0) || payload.count < 4 {
                cur = nil
                return nil
            }
            waiting = false
            let ts = UInt32(payload[payload.startIndex]) | (UInt32(payload[payload.startIndex+1]) << 8)
                | (UInt32(payload[payload.startIndex+2]) << 16) | (UInt32(payload[payload.startIndex+3]) << 24)
            cur = AU(flags: flags, ts: ts, data: Data(payload.dropFirst(4)))
        } else if var c = cur {
            c.data += payload
            cur = c
        }
        if flags & ChunkFlags.end != 0, let au = cur {
            cur = nil
            var a = au
            a.flags |= flags
            return a
        }
        return nil
    }
}
