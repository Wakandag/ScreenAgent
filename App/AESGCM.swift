import Foundation
import CommonCrypto

/// AES-128-GCM with a 12-byte tag, matching the board's protocol
/// (CommonCrypto GCM, tag size 12 — CryptoKit only does 16).
enum AESGCM {
    enum Error: Swift.Error { case setupFailed(OSStatus), authFailed }

    private static func makeCryptor(op: CCOperation, key: Data) throws -> CCCryptorRef {
        var ref: CCCryptorRef?
        let st = key.withUnsafeBytes { kb -> CCCryptorStatus in
            CCCryptorCreateWithMode(op, CCMode(kCCModeGCM), CCAlgorithm(kCCAlgorithmAES),
                                    CCPadding(ccNoPadding), nil, kb.baseAddress,
                                    key.count, nil, 0, 0, CCModeOptions(0), &ref)
        }
        guard st == kCCSuccess, let r = ref else { throw Error.setupFailed(st) }
        return r
    }

    private static func withSession<T>(op: CCOperation, key: Data, nonce: Data, aad: Data,
                                       _ body: (CCCryptorRef) throws -> T) throws -> T {
        let ref = try makeCryptor(op: op, key: key)
        defer { CCCryptorRelease(ref) }
        var st: CCCryptorStatus
        st = nonce.withUnsafeBytes { nb in CCCryptorGCMAddIV(ref, nb.baseAddress, nonce.count) }
        guard st == kCCSuccess else { throw Error.setupFailed(st) }
        st = aad.withUnsafeBytes { ab in CCCryptorGCMaddAAD(ref, ab.baseAddress, aad.count) }
        guard st == kCCSuccess else { throw Error.setupFailed(st) }
        return try body(ref)
    }

    static func seal(key: Data, nonce: Data, aad: Data, plain: Data) throws -> (ct: Data, tag: Data) {
        try withSession(op: kCCEncrypt, key: key, nonce: nonce, aad: aad) { ref in
            var out = Data(count: plain.count)
            var tag = Data(count: 12)
            var tagLen: Int = 12
            let st = plain.withUnsafeBytes { pb in
                out.withUnsafeMutableBytes { ob -> CCCryptorStatus in
                    CCCryptorGCMadd(ref, pb.baseAddress, plain.count, ob.baseAddress)
                }
            }
            guard st == kCCSuccess else { throw Error.setupFailed(st) }
            let st2 = tag.withUnsafeMutableBytes { tb in
                CCCryptorGCMFinal(ref, tb.baseAddress, &tagLen)
            }
            guard st2 == kCCSuccess else { throw Error.setupFailed(st2) }
            return (out, tag)
        }
    }

    /// Returns plaintext, or nil when the tag does not authenticate.
    static func open(key: Data, nonce: Data, aad: Data, ct: Data, tag: Data) -> Data? {
        guard tag.count == 12 else { return nil }
        do {
            return try withSession(op: kCCDecrypt, key: key, nonce: nonce, aad: aad) { ref in
                var out = Data(count: ct.count)
                let st = ct.withUnsafeBytes { cb in
                    out.withUnsafeMutableBytes { ob -> CCCryptorStatus in
                        CCCryptorGCMadd(ref, cb.baseAddress, ct.count, ob.baseAddress)
                    }
                }
                guard st == kCCSuccess else { return nil }
                var tagCalc = Data(count: 12)
                var tagLen: Int = 12
                let st2 = tagCalc.withUnsafeMutableBytes { tb in
                    CCCryptorGCMFinal(ref, tb.baseAddress, &tagLen)
                }
                guard st2 == kCCSuccess else { return nil }
                return tagCalc == tag ? out : nil
            }
        } catch { return nil }
    }
}
