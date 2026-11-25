import Foundation

/// The autonomous loop: watch the mirrored screen, keep the head centered,
/// and/or run the on-device LLM to realize a goal while you use the phone.
final class AgentLoop {
    struct Config {
        var headFollow = true
        var agentMode = false
        var goal = "keep the screen useful"
        var checkInterval: TimeInterval = 2.0
        var deadZone = 0.12          // fraction of half-screen before panning
        var maxSwipe = 0.7
        var settle: TimeInterval = 1.2
    }

    private let video: VideoPipe
    private let pointer: Pointer
    private let vision = VisionAnalyzer()
    private let llm: LLM
    var config = Config()
    var onLog: ((String) -> Void)?
    private(set) var running = false
    private var task: Task<Void, Never>?
    private let busy = NSLock()
    private var lastActionDesc = "start"

    init(video: VideoPipe, pointer: Pointer, llm: LLM) {
        self.video = video
        self.pointer = pointer
        self.llm = llm
    }

    func start() {
        guard !running else { return }
        running = true
        task = Task { [weak self] in await self?.run() }
    }

    func stop() {
        running = false
        task?.cancel()
        task = nil
    }

    private func log(_ s: String) { onLog?(s) }

    private func run() async {
        log("agent loop started")
        var lastShot = Date.distantPast
        var lastAction = Date.distantPast
        while running && !Task.isCancelled {
            do {
                try await Task.sleep(nanoseconds: UInt64(config.checkInterval * 1_000_000_000))
            } catch { break }
            guard running, video.isFresh else { continue }

            // 1) head-follow: free and instant, runs even while the LLM thinks
            if config.headFollow {
                await headFollowPass()
            }

            // 2) agent mode: LLM plans the next action from OCR text
            if config.agentMode {
                let now = Date()
                if now.timeIntervalSince(lastAction) >= config.checkInterval,
                   now.timeIntervalSince(lastShot) >= config.checkInterval {
                    lastShot = now
                    await agentPass()
                    lastAction = Date()
                }
            }
        }
        log("agent loop stopped")
    }

    // MARK: head-follow

    private func headFollowPass() async {
        guard let pb = video.latestPixelBuffer else { return }
        guard let face = await vision.faceCenter(pb) else { return }
        let dx = face.x - 0.5, dy = face.y - 0.5
        let deadX = max(config.deadZone * 0.5, face.size * 0.6)
        let deadY = max(config.deadZone * 0.5, face.size * 0.6)
        if abs(dx) < deadX && abs(dy) < deadY { return }
        let dist = (dx * dx + dy * dy).squareRoot()
        guard dist > 0.0001 else { return }
        let scale = min(1.0, config.maxSwipe / dist)
        var x1 = face.x, y1 = face.y
        var x2 = face.x - dx * scale, y2 = face.y - dy * scale
        // keep inside the screen
        let clamp: (Double, Double, Double) -> Double = { v, lo, hi in max(lo, min(hi, v)) }
        x1 = clamp(x1, 0.03, 0.97); y1 = clamp(y1, 0.03, 0.97)
        x2 = clamp(x2, 0.03, 0.97); y2 = clamp(y2, 0.03, 0.97)
        guard pointer.calibrated else { return }
        busy.lock()
        defer { busy.unlock() }
        do {
            log("head at (\(String(format: "%.2f", face.x)),\(String(format: "%.2f", face.y))) -> pan")
            try await pointer.swipe(nx1: x1, ny1: y1, nx2: x2, ny2: y2, hold: true)
            try await Task.sleep(nanoseconds: UInt64(config.settle * 1_000_000_000))
        } catch {
            log("pan failed: \(error)")
        }
    }

    // MARK: agent mode

    private func agentPass() async {
        guard let pb = video.latestPixelBuffer else { return }
        let text = await vision.ocr(pb)
        if text.isEmpty { return }
        do { try llm.load() } catch { log("model: \(error)"); config.agentMode = false; return }
        busy.lock()
        defer { busy.unlock() }
        let user = """
        GOAL: \(config.goal)
        LAST ACTION: \(lastActionDesc)
        SCREEN TEXT:
        \(text)
        Reply with one JSON action only.
        """
        let reply = llm.chat(system: LLM.systemPrompt, user: user)
        guard let action = LLM.parse(reply), let kind = action["action"] as? String else {
            log("llm: no usable action")
            return
        }
        lastActionDesc = describe(action)
        do {
            try await execute(action, kind: kind)
            try await Task.sleep(nanoseconds: UInt64(config.settle * 1_000_000_000))
        } catch {
            log("action failed: \(error)")
        }
    }

    private func describe(_ a: [String: Any]) -> String {
        let d = a["action"] as? String ?? "?"
        if d == "tap" { return "tap \(a["x"] ?? 0),\(a["y"] ?? 0)" }
        return d
    }

    private func execute(_ a: [String: Any], kind: String) async throws {
        let f = { (key: String) in (a[key] as? NSNumber)?.doubleValue ?? 0 }
        switch kind {
        case "tap":
            try await pointer.tap(nx: clamp01(f("x")), ny: clamp01(f("y")))
            log("tapped (\(f("x")), \(f("y")))")
        case "swipe":
            try await pointer.swipe(nx1: clamp01(f("x1")), ny1: clamp01(f("y1")),
                                    nx2: clamp01(f("x2")), ny2: clamp01(f("y2")))
            log("swiped")
        case "text":
            try await pointer.text(a["text"] as? String ?? "")
            log("typed text")
        case "key":
            try await pointer.key(a["key"] as? String ?? "enter")
            log("key")
        case "home":
            try await pointer.homeGesture()
            log("home gesture")
        case "wait":
            log("waiting")
        case "done":
            log("goal done")
            config.agentMode = false
        default:
            log("unknown action \(kind)")
        }
    }

    private func clamp01(_ v: Double) -> Double { max(0.0, min(1.0, v)) }
}
