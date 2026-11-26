import Foundation

/// Board protocol client for the app's own BLE service (...0000): command lines
/// out, replies + status JSON + H.264 chunks in. Security is the iPhone's bonded
/// LE link to the board, so there is no in-app pairing or session handshake.
final class BoardSession {
    enum Event {
        case state(String)
        case reply(String)
        case status(Data)
        case video(Data, gap: Bool)
        case boardError(String)
    }

    var onEvent: ((Event) -> Void)?
    private var listeners: [(Event) -> Void] = []

    /// Every video chunk ([seq u16 LE][flags u8][payload]) for the decoder.
    var onVideoChunk: ((Data, Bool) -> Void)?
    /// Sink for one command line ("<id> <command>").
    var outbound: ((String) -> Void)?

    private(set) var boardID = Data()
    private var opened = false
    private var nextID = 0

    var isPaired: Bool { true }        // the LE bond with the board is the pairing
    var hasSession: Bool { opened }
    var pairing: Bool { false }
    var opening: Bool { false }
    var boardIDHex: String { boardID.hex }

    // MARK: Session

    /// Nothing to pair: the phone is already bonded to the board.
    func pair() async throws {
        emit(.state("paired"))
    }

    func open() async throws {
        opened = true
        emit(.state("session"))
    }

    /// Sends "<id> <command>". A line that already carries its own id (Pointer's
    /// "<id> move dx dy") is sent unchanged.
    func sendCommand(_ line: String) throws {
        guard opened else {
            throw NSError(domain: "board", code: 2, userInfo: [NSLocalizedDescriptionKey: "no session"])
        }
        guard let outbound else {
            throw NSError(domain: "board", code: 1, userInfo: [NSLocalizedDescriptionKey: "link not ready"])
        }
        nextID += 1
        let text = (line.first?.isNumber ?? false) ? line : "\(nextID) \(line)"
        outbound(text)
    }

    // MARK: Inbound (called by BLELink on the main queue)

    func handleReply(_ text: String) {
        emit(.reply(text.trimmingCharacters(in: .whitespacesAndNewlines)))
    }

    func handleStatus(_ data: Data) {
        if let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id = obj["id"] as? String, let raw = Data(hex: id) {
            boardID = raw
        }
        emit(.status(data))
    }

    func handleVideo(_ chunk: Data) {
        onVideoChunk?(chunk, false)
    }

    /// The BLE link dropped: the session cannot survive it.
    func linkLost() {
        guard opened else { return }
        opened = false
        emit(.state("link lost"))
    }

    func addListener(_ l: @escaping (Event) -> Void) { listeners.append(l) }

    private func emit(_ e: Event) {
        onEvent?(e)
        for l in listeners { l(e) }
    }
}

extension Data {
    var hex: String { map { String(format: "%02x", $0) }.joined() }
    init?(hex: String) {
        let h = hex.replacingOccurrences(of: " ", with: "")
        guard h.count % 2 == 0 else { return nil }
        var d = Data()
        var idx = h.startIndex
        while idx < h.endIndex {
            let next = h.index(idx, offsetBy: 2)
            guard let b = UInt8(h[idx..<next], radix: 16) else { return nil }
            d.append(b)
            idx = next
        }
        self = d
    }
}
