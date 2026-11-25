import Foundation
import CommonCrypto

/// AES-128-GCM with a 12-byte tag, matching the board's protocol.
/// Built from the AES block cipher (CommonCrypto ECB on single blocks)
/// plus GHASH — Xcode 16's CommonCrypto Swift overlay does not expose
/// the CCCryptorGCM* API, and CryptoKit only does 16-byte tags.
enum AESGCM {
    enum Error: Swift.Error { case authFailed, setupFailed(OSStatus) }

    // MARK: AES block via CommonCrypto ECB (16-byte blocks, no padding)

    private static func aesBlock(_ key: Data, _ block: [UInt8]) -> [UInt8] {
        var out = [UInt8](repeating: 0, count: 16)
        var moved = 0
        let st = key.withUnsafeBytes { kb -> CCCryptorStatus in
            block.withUnsafeBytes { bb in
                out.withUnsafeMutableBytes { ob in
                    CCCrypt(CCOperation(kCCEncrypt), CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(kCCOptionECBMode), kb.baseAddress, 16, nil,
                            bb.baseAddress, 16, ob.baseAddress, 16, &moved)
                }
            }
        }
        precondition(st == kCCSuccess, "AES block failed: \(st)")
        return out
    }

    // MARK: GF(2^128) multiplication (GCM convention, MSB-first bits)

    static func gfMul(_ x: [UInt8], _ h: [UInt8]) -> [UInt8] {
        var z = [UInt8](repeating: 0, count: 16)
        var v = h
        for i in 0..<128 {
            let bit = (x[i / 8] >> UInt8(7 - (i % 8))) & 1
            if bit == 1 {
                for j in 0..<16 { z[j] ^= v[j] }
            }
            let lsb = v[15] & 1
            for j in stride(from: 15, through: 1, by: -1) {
                v[j] = (v[j] >> 1) | ((v[j - 1] & 1) << 7)
            }
            v[0] >>= 1
            if lsb == 1 { v[0] ^= 0xE1 }
        }
        return z
    }

    // MARK: GHASH over AAD || pad || CT || pad || lens

    static func ghash(_ h: [UInt8], aad: Data, ct: Data) -> [UInt8] {
        var y = [UInt8](repeating: 0, count: 16)
        func absorb(_ d: Data) {
            var blocks: [[UInt8]] = []
            let bytes = [UInt8](d)
            var i = 0
            while i < bytes.count {
                var b = Array(bytes[i..<min(i + 16, bytes.count)])
                while b.count < 16 { b.append(0) }
                blocks.append(b)
                i += 16
            }
            for b in blocks {
                for j in 0..<16 { y[j] ^= b[j] }
                y = gfMul(y, h)
            }
        }
        absorb(aad)
        absorb(ct)
        var lens = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: UInt64(aad.count * 8).bigEndian) { for (j, b) in $0.enumerated() { lens[j] = b } }
        withUnsafeBytes(of: UInt64(ct.count * 8).bigEndian) { for (j, b) in $0.enumerated() { lens[8 + j] = b } }
        for j in 0..<16 { y[j] ^= lens[j] }
        return gfMul(y, h)
    }

    // MARK: CTR stream (inc32 over the last 4 bytes, big-endian per spec)

    private static func ctrStream(_ key: Data, _ j0: [UInt8], _ data: Data) -> Data {
        var out = [UInt8]()
        out.reserveCapacity(data.count)
        var cb = j0
        let bytes = [UInt8](data)
        var i = 0
        while i < bytes.count {
            let ks = aesBlock(key, cb)
            let n = min(16, bytes.count - i)
            for k in 0..<n { out.append(bytes[i + k] ^ ks[k]) }
            i += n
            // inc32
            var c: UInt32 = 0
            for k in 12..<16 { c = (c << 8) | UInt32(cb[k]) }
            c &+= 1
            for k in (12..<16).reversed() { cb[k] = UInt8(truncatingIfNeeded: c); c >>= 8 }
        }
        return Data(out)
    }

    private static func j0(_ nonce: Data) -> [UInt8] {
        precondition(nonce.count == 12, "protocol nonces are 12 bytes")
        var j = [UInt8](nonce)
        j += [0, 0, 0, 1]
        return j
    }

    // MARK: Public API — same shapes as before

    static func seal(key: Data, nonce: Data, aad: Data, plain: Data) throws -> (ct: Data, tag: Data) {
        precondition(key.count == 16)
        let j = j0(nonce)
        var start = j
        // inc32: the data stream begins at inc32(J0); J0 itself is only the tag mask
        var c: UInt32 = 0
        for k in 12..<16 { c = (c << 8) | UInt32(start[k]) }
        c &+= 1
        for k in (12..<16).reversed() { start[k] = UInt8(truncatingIfNeeded: c); c >>= 8 }
        let ct = ctrStream(key, start, plain)
        let h = aesBlock(key, [UInt8](repeating: 0, count: 16))
        var s = ghash(h, aad: aad, ct: ct)
        let e0 = aesBlock(key, j)
        for k in 0..<16 { s[k] ^= e0[k] }
        return (ct, Data(s.prefix(12)))   // protocol tag is 12 bytes
    }

    /// Returns plaintext, or nil when the tag does not authenticate.
    static func open(key: Data, nonce: Data, aad: Data, ct: Data, tag: Data) -> Data? {
        guard tag.count == 12 else { return nil }
        do {
            let (good, t) = try seal(key: key, nonce: nonce, aad: aad, plain: ct)
            if t == tag { return good }
            return nil
        } catch { return nil }
    }
}
