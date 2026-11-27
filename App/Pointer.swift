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
    /// Measured aim correction: a commanded unit offset u puts the cursor at
    /// v = gain * u + offset. Identity until a mapping check measures it.
    private var gainX = 1.0, gainY = 1.0, offX = 0.0, offY = 0.0
    var onLog: ((String) -> Void)?

    private let gapBetweenKeys: UInt64 = 80_000_000   // 80 ms, iOS drops back-to-back keys otherwise

    init(session: BoardSession, video: VideoPipe) {
        self.session = session
        self.video = video
        if let raw = UserDefaults.standard.string(forKey: "span") {
            let p = raw.split(separator: "x").compactMap { Int($0) }
            if p.count == 2 { spanW = p[0]; spanH = p[1] }
        }
        if let m = UserDefaults.standard.stringArray(forKey: "pmap"), m.count == 4,
           let gx = Double(m[0]), let gy = Double(m[1]),
           let ox = Double(m[2]), let oy = Double(m[3]) {
            gainX = gx; gainY = gy; offX = ox; offY = oy
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
        // Undo the measured aim error: commanded = (target - offset) / gain.
        let dx = Int(((min(max(nx, 0), 1) * Double(spanW) - offX) / gainX).rounded())
        let dy = Int(((min(max(ny, 0), 1) * Double(spanH) - offY) / gainY).rounded())
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

    // MARK: Mapping check

    private func f3(_ v: Double) -> String { String(format: "%.3f", v) }

    /// Park at home, move to the commanded unit offset, wiggle, and report where
    /// the cursor actually shows up as screen fractions.
    private func observe(ux: Int, uy: Int, wiggle: Int = 10) async throws -> (x: Double, y: Double) {
        try await home()
        try await move(dx: ux, dy: uy)
        try await Task.sleep(nanoseconds: 1_000_000_000)
        let before = try await freshSnapshot()
        try await move(dx: wiggle, dy: 0)
        try await Task.sleep(nanoseconds: 800_000_000)
        let after = try await freshSnapshot()
        try await move(dx: -wiggle, dy: 0)
        guard let p = FrameDiff.locate(before: before, after: after) else { throw PointerError.notFound }
        return (p.x - Double(wiggle) / Double(spanW), p.y)
    }

    /// A link drop mid-observation shows up as a timeout; restarting from home
    /// makes the whole measurement safe to repeat.
    private func observeWithRetry(ux: Int, uy: Int) async throws -> (x: Double, y: Double) {
        var last: Swift.Error = PointerError.timeout
        for attempt in 0..<3 {
            do { return try await observe(ux: ux, uy: uy) }
            catch {
                last = error
                onLog?("pointer: sample retry \(attempt + 1) (\(error))")
                try? await Task.sleep(nanoseconds: 1_500_000_000)
            }
        }
        throw last
    }

    /// Least squares fit of v = a*u + b.
    private func fit(_ s: [(u: Double, v: Double)]) -> (a: Double, b: Double)? {
        let n = Double(s.count)
        guard n >= 2 else { return nil }
        let su = s.reduce(0.0) { $0 + $1.u }, sv = s.reduce(0.0) { $0 + $1.v }
        let suu = s.reduce(0.0) { $0 + $1.u * $1.u }, suv = s.reduce(0.0) { $0 + $1.u * $1.v }
        let den = n * suu - su * su
        guard abs(den) > 1e-6 else { return nil }
        let a = (n * suv - su * sv) / den
        return (a, (sv - a * su) / n)
    }

    /// Aim at known screen points, measure where the cursor really lands, learn the
    /// correction and re-check it.
    func verifyMapping() async throws {
        guard calibrated else { throw PointerError.notCalibrated }
        var xs: [(u: Double, v: Double)] = [], ys: [(u: Double, v: Double)] = []
        for (tx, ty) in [(0.25, 0.25), (0.70, 0.30), (0.40, 0.70)] as [(Double, Double)] {
            let ux = (tx * Double(spanW) - offX) / gainX
            let uy = (ty * Double(spanH) - offY) / gainY
            do {
                let p = try await observeWithRetry(ux: Int(ux.rounded()), uy: Int(uy.rounded()))
                xs.append((ux, p.x * Double(spanW)))
                ys.append((uy, p.y * Double(spanH)))
                onLog?("pointer: aimed \(f3(tx)),\(f3(ty)) -> cursor \(f3(p.x)),\(f3(p.y)) off \(f3(p.x - tx)),\(f3(p.y - ty))")
            } catch {
                onLog?("pointer: sample \(f3(tx)),\(f3(ty)) failed: \(error)")
            }
        }
        guard xs.count >= 2, ys.count >= 2 else {
            onLog?("pointer: not enough samples to fit a correction")
            return
        }
        guard let fx = fit(xs), let fy = fit(ys),
              (0.5...1.8).contains(fx.a), (0.5...1.8).contains(fy.a) else {
            onLog?("pointer: measurement noisy, keeping span \(spanW)x\(spanH)")
            return
        }
        gainX = fx.a; offX = fx.b; gainY = fy.a; offY = fy.b
        UserDefaults.standard.set([String(gainX), String(gainY), String(offX), String(offY)], forKey: "pmap")
        onLog?("pointer: mapping x gain \(f3(gainX)) off \(f3(offX)) / y gain \(f3(gainY)) off \(f3(offY))")
        for (tx, ty) in [(0.5, 0.5), (0.22, 0.78)] as [(Double, Double)] {
            let ux = (tx * Double(spanW) - offX) / gainX
            let uy = (ty * Double(spanH) - offY) / gainY
            do {
                let p = try await observeWithRetry(ux: Int(ux.rounded()), uy: Int(uy.rounded()))
                onLog?("pointer: check \(f3(tx)),\(f3(ty)) -> cursor \(f3(p.x)),\(f3(p.y)) off \(f3(p.x - tx)),\(f3(p.y - ty))")
            } catch {
                onLog?("pointer: check \(f3(tx)),\(f3(ty)) failed: \(error)")
            }
        }
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
        gainX = 1; gainY = 1; offX = 0; offY = 0
        UserDefaults.standard.removeObject(forKey: "pmap")   // a fresh span invalidates it
        saveSpan()
        onLog?("calibrated: span \(w)x\(h)")
    }
}
