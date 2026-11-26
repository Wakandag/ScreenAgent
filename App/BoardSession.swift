import Foundation
import CryptoKit

/// Board protocol client: pairing, session keys, DATA frames (docs/cli-protocol.md).
final class BoardSession {
    enum Event {
        case state(String)
        case reply(String)
        case status(Data)
        case video(Data, gap: Bool)
        case boardError(String)
    }

    static let pairSalt = "esp32agent-pair-v1"
    static let sessionInfo = "esp32agent-session-v1"
    static let serviceBase = "6e400001-a9e8-4b1b-9c39-6d6f8a3c"

    private var k: Data?                       // 32-byte key, one per (client, board)
    private(set) var clientID: Data            // 16 bytes, refreshed at each pairing
    private(set) var boardID = Data()
    private var cPriv: Curve25519.KeyAgreement.PrivateKey!
    private var cPub = Data()
    private var cNonce = Data()
    private var c2b = Data()
    private var b2c = Data()
    private var ctrC: UInt32 = 0, ctrB: UInt32 = 0, ctrV: UInt32 = 0, ctrA: UInt32 = 0
    private var expectedBoardID: Data?

    var onEvent: ((Event) -> Void)?
    private var listeners: [(Event) -> Void] = []
    private var pairWaiter: CheckedContinuation<Void, Swift.Error>?
    private var sessionWaiter: CheckedContinuation<Void, Swift.Error>?

    init() {
        if let raw = UserDefaults.standard.data(forKey: "clientID") {
            clientID = raw
        } else {
            clientID = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
            UserDefaults.standard.set(clientID, forKey: "clientID")
        }
        if let bid = UserDefaults.standard.string(forKey: "lastBoardID") {
            expectedBoardID = Data(hex: bid)
        }
        if let kid = UserDefaults.standard.string(forKey: "lastBoardID"),
           let kk = UserDefaults.standard.data(forKey: "K.\(kid)"),
           let bid = Data(hex: kid) {
            k = kk
            boardID = bid
        }
    }

    var isPaired: Bool { k != nil }
    var pairing: Bool { pairWaiter != nil }
    var opening: Bool { sessionWaiter != nil }
    var hasSession: Bool { !c2b.isEmpty }
    var boardIDHex: String { boardID.hex }

    // MARK: Pairing (only within 3 min of board power-on)

    func pair() async throws {
        guard !hasSession else { return }
        cPriv = Curve25519.KeyAgreement.PrivateKey()
        cPub = cPriv.publicKey.rawRepresentation
        // fresh random client id per pairing attempt (the board MACs over it)
        let cid = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        clientID = cid
        UserDefaults.standard.set(cid, forKey: "clientID")
        emit(.state("pairing"))
        try send([0x01] + cPub + cid)
        // PAIRED arrives via feed()
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Swift.Error>) in
            self.pairWaiter = c
        }
    }

    // MARK: Session

    func open() async throws {
        guard let k = k else {
            throw NSError(domain: "board", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "not paired yet: unplug and replug the board, then Pair within 3 minutes"])
        }
        guard !hasSession else { return }
        cNonce = Data((0..<16).map { _ in UInt8.random(in: 0...255) })
        emit(.state("connecting"))
        try send([0x02] + clientID + cNonce)
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Swift.Error>) in
            self.sessionWaiter = c
        }
    }

    func sendCommand(_ line: String) throws {
        guard hasSession else {
            throw NSError(domain: "board", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "no session"])
        }
        ctrC += 1
        let plain = Data("c".utf8) + Data(line.utf8)
        try send(seal(stream: UInt8(ascii: "C"), type: 0x10, ctr: ctrC, plain: plain))
    }

    // MARK: Inbound

    func feed(_ frame: Data) {
        guard !frame.isEmpty else { return }
        switch frame[0] {
        case 0x81: handlePaired(Data(frame.dropFirst()))
        case 0x82: handleWelcome(Data(frame.dropFirst()))
        case 0x10:
            guard !b2c.isEmpty else { return }
            let (ctrCin, plainCin) = openCtr(frame, stream: UInt8(ascii: "B"))
            guard let plain = plainCin else { return }
            guard ctrCin > ctrB else { return }
            guard ctrCin == ctrB + 1 else { sessionDied(); return }
            ctrB = ctrCin
            guard let kind = plain.first else { return }
            let body = plain.dropFirst()
            switch kind {
            case UInt8(ascii: "r"): emit(.reply(String(decoding: body, as: UTF8.self)))
            case UInt8(ascii: "s"): emit(.status(Data(body)))
            default: break
            }
        case 0x11:
            guard !b2c.isEmpty else { return }
            let (ctrVin, plainVin) = openCtr(frame, stream: UInt8(ascii: "V"))
            guard let plain = plainVin, ctrVin > ctrV else { return }
            let gap = ctrVin != ctrV + 1
            ctrV = ctrVin
            emit(.video(plain, gap: gap))
        case 0x12:
            guard !b2c.isEmpty else { return }
            let (ctrAin, _) = openCtr(frame, stream: UInt8(ascii: "A"))
            guard ctrAin > ctrA else { return }
            ctrA = ctrAin   // audio not used yet; keep the counter alive
        case 0xE0:
            emit(.boardError(String(decoding: frame.dropFirst(), as: UTF8.self)))
        default: break
        }
    }

    private func handlePaired(_ body: Data) {
        guard body.count >= 38 + 16, k == nil else { resumeWaiter(&pairWaiter,
            NSError(domain: "board", code: 3,
                    userInfo: [NSLocalizedDescriptionKey: "unexpected PAIRED"])); return }
        let bPub = Data(body.prefix(32))
        boardID = Data(body[32..<38])
        let mac = Data(body[38..<54])
        do {
            let pk = try Curve25519.KeyAgreement.PublicKey(rawRepresentation: bPub)
            let shared = try cPriv.sharedSecretFromKeyAgreement(with: pk)
            let sharedRaw = shared.withUnsafeBytes { Data($0) }
            let key = Self.hkdf(ikm: sharedRaw, salt: Data(Self.pairSalt.utf8), info: cPub + bPub)
            let expect = Self.mac(key, Data("paired".utf8), clientID)
            guard expect == mac else {
                resumeWaiter(&pairWaiter, NSError(domain: "board", code: 4,
                    userInfo: [NSLocalizedDescriptionKey: "pairing MAC mismatch"])); return
            }
            k = key
            UserDefaults.standard.set(boardID.hex, forKey: "lastBoardID")
            UserDefaults.standard.set(key, forKey: "K.\(boardID.hex)")
            emit(.state("paired"))
            resumeWaiter(&pairWaiter, nil)
        } catch {
            resumeWaiter(&pairWaiter, error)
        }
    }

    private func handleWelcome(_ body: Data) {
        guard body.count >= 16 + 6 + 16, let k else { resumeWaiter(&sessionWaiter,
            NSError(domain: "board", code: 5,
                    userInfo: [NSLocalizedDescriptionKey: "unexpected WELCOME"])); return }
        let bNonce = Data(body.prefix(16))
        boardID = Data(body[16..<22])
        let mac = Data(body[22..<38])
        guard Self.mac(k, Data("hello".utf8), cNonce, bNonce) == mac else {
            resumeWaiter(&sessionWaiter, NSError(domain: "board", code: 6,
                userInfo: [NSLocalizedDescriptionKey: "hello MAC mismatch"])); return
        }
        let okm = Self.hkdf(ikm: k, salt: cNonce + bNonce, info: Data(Self.sessionInfo.utf8))
        c2b = okm.prefix(16)
        b2c = okm.suffix(16)
        ctrC = 0; ctrB = 0; ctrV = 0; ctrA = 0
        emit(.state("session"))
        resumeWaiter(&sessionWaiter, nil)
    }

    private func sessionDied() {
        c2b = Data(); b2c = Data()
        ctrC = 0; ctrB = 0; ctrV = 0; ctrA = 0
        emit(.state("session died"))
    }

    private func resumeWaiter(_ c: inout CheckedContinuation<Void, Swift.Error>?, _ err: Swift.Error?) {
        if let waiter = c {
            c = nil
            err == nil ? waiter.resume() : waiter.resume(throwing: err!)
        }
    }

    // MARK: Crypto helpers

    /// Parse the plaintext header [type u8][ctr u32 LE] and decrypt the rest with k_b2c.
    private func openCtr(_ frame: Data, stream: UInt8) -> (UInt32, Data?) {
        guard frame.count > 5 + 12, !b2c.isEmpty else { return (0, nil) }
        let ctr = UInt32(frame[1]) | (UInt32(frame[2]) << 8) | (UInt32(frame[3]) << 16) | (UInt32(frame[4]) << 24)
        let plain = AESGCM.open(key: b2c, nonce: Self.nonce(stream, ctr),
                                aad: Data(frame.prefix(5)),
                                ct: Data(frame.dropFirst(5).dropLast(12)),
                                tag: Data(frame.suffix(12)))
        return (ctr, plain)
    }

    func addListener(_ l: @escaping (Event) -> Void) { listeners.append(l) }

    private func emit(_ e: Event) {
        onEvent?(e)
        for l in listeners { l(e) }
    }

    var outbound: ((Data) -> Void)?

    private func send(_ frame: Data) throws {
        guard let outbound else {
            throw NSError(domain: "board", code: 7,
                          userInfo: [NSLocalizedDescriptionKey: "no BLE link attached"])
        }
        outbound(frame)
    }

    /// RFC 5869 HKDF-SHA256 (extract with `salt`, expand with `info`).
    static func hkdf(ikm: Data, salt: Data, info: Data, length: Int = 32) -> Data {
        let prk = Data(HMAC<SHA256>.authenticationCode(for: ikm, using: SymmetricKey(data: salt)))
        var okm = Data()
        var t = Data()
        var counter: UInt8 = 1
        while okm.count < length {
            t = Data(HMAC<SHA256>.authenticationCode(for: t + info + Data([counter]),
                                                     using: SymmetricKey(data: prk)))
            okm += t
            counter = counter &+ 1
        }
        return okm.prefix(length)
    }

    static func mac(_ key: Data, _ parts: Data...) -> Data {
        var msg = Data()
        for p in parts { msg += p }
        return Data(HMAC<SHA256>.authenticationCode(for: msg, using: SymmetricKey(data: key)).prefix(16))
    }

    static func nonce(_ stream: UInt8, _ ctr: UInt32) -> Data {
        var n = Data([stream, 0, 0, 0, 0, 0, 0, 0])
        withUnsafeBytes(of: ctr.littleEndian) { n += Data($0) }
        return n   // 12 bytes
    }

    private func seal(stream: UInt8, type: UInt8, ctr: UInt32, plain: Data) -> Data {
        guard !c2b.isEmpty else { return Data() }
        var hdr = Data([type])
        withUnsafeBytes(of: ctr.littleEndian) { hdr += Data($0) }
        guard let (ct, tag) = try? AESGCM.seal(key: c2b, nonce: Self.nonce(stream, ctr),
                                               aad: hdr, plain: plain) else { return Data() }
        return hdr + ct + tag
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
