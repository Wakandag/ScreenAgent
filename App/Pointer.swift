import Foundation

/// Drives the board's HID-mouse pointer: relative moves with a learned
/// span (units per full screen). Port of the CLI's Pointer, simplified.
final class Pointer {
    private let session: BoardSession
    private let video: VideoPipe
    private var nextID = 0
    private var pending: [String: CheckedContinuation<String, Swift.Error>] = [:]
    private let lock = NSLock()

    private(set) var spanW = 0, spanH = 0
    var calibrated: Bool { spanW > 0 && spanH > 0 }
    var onLog: ((String) -> Void)?

    private let gapBetweenKeys: UInt64 = 80_000_000   // 80 ms, iOS drops back-to-back keys otherwise

    init(session: BoardSession, video: VideoPipe) {
        self.session = session
        self.video = video
        if let raw = UserDefaults.standard.string(forKey: "span") {
            let p = raw.split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { spanW = p[0]; spanH = p[1] }
        }
        session.addListener { [weak self] e in
            guard let self else { return }
            switch e {
            case .reply(let line):
                let parts = line.split(separator: " ", maxSplits: 1)
                guard let id = parts.first, !parts.isEmpty else { return }
                self.lock.lock()
                let waiter = self.pending[String(id)]
                self.pending.removeValue(forKey: String(id))
                self.lock.unlock()
                guard let w = waiter else { return }
                let rest = parts.count > 1 ? String(parts[1]) : ""
                if rest == "ok" || rest.hasPrefix("ok ") {
                    w.resume(returning: rest == "ok" ? "" : String(rest.dropFirst(3)))
                } else if rest.hasPrefix("err") {
                    let msg = rest.count > 3 ? String(rest.dropFirst(4)) : rest
                    w.resume(throwing: PointerError.board(msg))
                } else {
                    w.resume(returning: rest)
                }
            default: break
            }
        }
    }

    enum PointerError: Swift.Error {
        case board(String)
        case notCalibrated
        case timeout
        case notFound
    }

    func saveSpan() {
        UserDefaults.standard.set("\(spanW)x\(spanH)", forKey: "span")
    }

    func send(_ line: String, timeout: TimeInterval = 8) async throws -> String {
        nextID += 1
        let id = String(nextID)
        do {
            return try await withTimeout(seconds: timeout) { [self] in
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<String, Swift.Error>) in
                    lock.lock()
                    pending[id] = c
                    lock.unlock()
                    try? session.sendCommand(id + " " + line)
                }
            }
        } catch {
            lock.lock()
            pending.removeValue(forKey: id)   // late replies find nothing and are dropped
            lock.unlock()
            throw error
        }
    }

    private func withTimeout<T: Sendable>(seconds: TimeInterval, _ body: @escaping () async throws -> T) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask { try await body() }
            group.addTask {
                try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                throw PointerError.timeout
            }
            guard let first = try await group.next() else { throw PointerError.timeout }
            group.cancelAll()
            return first
        }
    }

    // MARK: Primitive commands

    func home() async throws { _ = try await send("home") }
    func click(count: Int = 1) async throws {
        for _ in 0..<max(count, 1) { _ = try await send("click") }
    }
    func press() async throws { _ = try await send("press") }
    func release() async throws { _ = try await send("release") }
    func key(_ combo: String) async throws { _ = try await send("key \(combo)") }
    func goHome() async throws { _ = try await send("home"); }   // board home = pointer home

    /// iOS Home = flick up from the home bar.
    func homeGesture() async throws {
        try await swipe(nx1: 0.5, ny1: 0.99, nx2: 0.5, ny2: 0.2, hold: false)
    }

    func text(_ ascii: String) async throws {
        let clean = String(ascii.filter { $0.isASCII && !$0.isNewline })
        guard !clean.isEmpty else { return }
        _ = try await send("text \(clean)")
    }

    func move(dx: Int, dy: Int) async throws {
        if dx != 0 { _ = try await send("move \(dx) 0") }
        if dy != 0 { _ = try await send("move 0 \(dy)") }
    }

    // MARK: Normalized operations

    func point(nx: Double, ny: Double) async throws {
        guard calibrated else { throw PointerError.notCalibrated }
        let dx = Int(min(max(nx, 0), 1) * Double(spanW))
        let dy = Int(min(max(ny, 0), 1) * Double(spanH))
        try await home()
        try await move(dx: dx, dy: dy)
    }

    func tap(nx: Double, ny: Double, count: Int = 1) async throws {
        try await point(nx: nx, ny: ny)
        try await click(count: count)
    }

    func longPress(nx: Double, ny: Double, seconds: Double = 1.0) async throws {
        try await point(nx: nx, ny: ny)
        try await press()
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        try await release()
    }

    func swipe(nx1: Double, ny1: Double, nx2: Double, ny2: Double, hold: Bool = true) async throws {
        guard calibrated else { throw PointerError.notCalibrated }
        try await point(nx: nx1, ny: ny1)
        try await press()
        try await move(dx: Int((nx2 - nx1) * Double(spanW)), dy: Int((ny2 - ny1) * Double(spanH)))
        if hold { try await Task.sleep(nanoseconds: 250_000_000) }
        try await release()
    }

    // MARK: Calibration

    /// A static mirrored screen makes AirPlay emit almost nothing, so ask the board
    /// for the current GOP ('snap') and wait for the decoder to hand us a frame.
    private func freshSnapshot(timeout: TimeInterval = 2.5) async throws -> (w: Int, h: Int, data: [UInt8]) {
        for _ in 0..<3 {
            try? await session.sendCommand("snap")
            var waited: TimeInterval = 0
            while waited < timeout {
                if let s = video.graySnapshot() { return s }
                try await Task.sleep(nanoseconds: 200_000_000)
                waited += 0.2
            }
        }
        onLog?("calibration: no video frame")
        throw PointerError.notFound
    }

    /// One-point calibration: home, move 200 diagonal, find the cursor by wiggling + frame diff.
    func calibrate() async throws {
        try await home()
        try await move(dx: 200, dy: 200)
        try await Task.sleep(nanoseconds: 1_200_000_000)   // iOS glides the pointer over ~1 s
        let before = try await freshSnapshot()
        try await move(dx: 12, dy: 0)
        try await Task.sleep(nanoseconds: 900_000_000)
        let after = try await freshSnapshot()
        try await move(dx: -12, dy: 0)
        try await Task.sleep(nanoseconds: 900_000_000)
        guard let pt = FrameDiff.locate(before: before, after: after),
              pt.x > 0.02, pt.x < 0.98, pt.y > 0.02, pt.y < 0.98 else {
            onLog?("calibration: cursor not visible on screen")
            throw PointerError.notFound
        }
        let w = Int((200.0 / pt.x).rounded()), h = Int((200.0 / pt.y).rounded())
        guard (100..<5000).contains(w), (100..<5000).contains(h) else {
            onLog?("calibration: implausible span \(w)x\(h), cursor not found")
            throw PointerError.notFound
        }
        spanW = w; spanH = h
        saveSpan()
        onLog?("calibrated: span \(w)x\(h)")
    }
}
