import SwiftUI

@MainActor
final class AgentViewModel: ObservableObject {
    @Published var state = "idle"
    @Published var boardStatus = ""
    @Published var battery = ""
    @Published var calibrated = false
    @Published var modelReady = false
    @Published var headFollow = true
    @Published var agentMode = false
    @Published var goal = "open the settings app and turn on airplane mode"
    @Published var log: [String] = []
    @Published var frameImage: UIImage?
    /// While a pointer measurement runs the phone shows this app, so its own
    /// redraws (log lines, status text, mirrored preview) would swamp the frame
    /// diff. Frozen UI keeps the mirrored screen still except for the cursor.
    @Published var quiet = false
    private var quietBuffer: [String] = []

    let link = BLELink()
    let session = BoardSession()
    let video = VideoPipe()
    let llm = LLM()
    lazy var pointer = Pointer(session: session, video: video)
    lazy var loop: AgentLoop = AgentLoop(video: video, pointer: pointer, llm: llm)

    private var statusTimer: Timer?
    private var autoTimer: Timer?
    private var autoPilot = false
    private var lastPairAttempt = Date.distantPast
    private var lastOpenAttempt = Date.distantPast
    private var lastScanStart = Date.distantPast
    private var lastDecodeErrors = 0

    init() {
        session.outbound = { [weak self] line in
            try? self?.link.write(line)
        }
        session.onVideoChunk = { [weak self] chunk, gap in
            self?.video.feed(chunk, gap: gap)
        }
        video.onLog = { [weak self] line in self?.appendLog(line) }
        link.onReply = { [weak self] line in
            self?.session.handleReply(line)
        }
        link.onStatus = { [weak self] data in
            self?.session.handleStatus(data)
        }
        link.onVideo = { [weak self] chunk in
            self?.session.handleVideo(chunk)
        }
        link.onState = { [weak self] s in
            guard let self else { return }
            self.appendLog("link: \(s.rawValue)")
            if s == .lost { self.session.linkLost() }
            Task { @MainActor in self.autoTick() }
        }
        session.onEvent = { [weak self] e in
            guard let self else { return }
            switch e {
            case .state(let s):
                self.appendLog("board: \(s)")
                Task { @MainActor in self.state = s }
            case .status(let d):
                if let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] {
                    let parts = j.map { "\($0.key)=\($0.value)" }.sorted().joined(separator: " ")
                    Task { @MainActor in
                        guard !self.quiet else { return }
                        self.boardStatus = parts
                        if let b = j["battery"] as? Int { self.battery = "\(b)%" }
                    }
                }
            case .boardError(let msg):
                self.appendLog("board error: \(msg)")
            default: break
            }
        }
        pointer.onLog = { [weak self] in self?.appendLog($0) }
        video.onNewFrame = { [weak self] in
            Task { @MainActor in
                guard let self, !self.quiet else { return }
                guard self.frameImage == nil || Int.random(in: 0..<15) == 0 else { return }
                self.frameImage = self.video.uiImage()
            }
        }
        loop.onLog = { [weak self] in self?.appendLog($0) }
        startStatusTimer()
        startAuto()
        // Dropping a file named verify.txt into the app's Documents folder makes the
        // next launch run the pointer check once the link and video are up, so the
        // check can be triggered without scrolling down to the button.
        let verifyFlag = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)
            .first?.appendingPathComponent("verify.txt")
        if let verifyFlag, FileManager.default.fileExists(atPath: verifyFlag.path) {
            try? FileManager.default.removeItem(at: verifyFlag)
            Task { [weak self] in
                guard let self else { return }
                var waited = 0
                while waited < 45, !(self.state == "session" && self.video.isFresh) {
                    try? await Task.sleep(nanoseconds: 1_000_000_000)
                    waited += 1
                }
                self.appendLog("pointer: auto check starting")
                self.verifyPointer()
            }
        }
    }

    // MARK: Auto connect / pair / open

    /// Keeps the link up without taps: scan at launch, pair the moment the board
    /// shows up (the board only accepts pairing in the 3 min after power-on), then
    /// open the encrypted session and request the video stream.
    func startAuto() {
        guard !autoPilot else { return }
        autoPilot = true
        autoTimer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.autoTick() }
        }
        link.start()
        lastScanStart = Date()
        appendLog("auto: scanning for ESP32 Agent ...")
    }

    private func autoTick() {
        guard autoPilot else { return }
        guard link.state == .ready else {
            // BLELink rescans on its own after a drop; only nudge it if the scan
            // stopped for good (e.g. the app came back from the background).
            if link.state != .connecting, Date().timeIntervalSince(lastScanStart) > 10 {
                lastScanStart = Date()
                link.start()
            }
            return
        }
        guard !(session.hasSession && state == "session") else { return }
        if session.isPaired {
            guard !session.opening, Date().timeIntervalSince(lastOpenAttempt) > 5 else { return }
            lastOpenAttempt = Date()
            appendLog("auto: opening session")
            openSession()
        } else {
            guard !session.pairing, Date().timeIntervalSince(lastPairAttempt) > 8 else { return }
            lastPairAttempt = Date()
            appendLog("auto: board found, pairing")
            pair()
        }
    }

    private func startStatusTimer() {
        statusTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.calibrated = self.pointer.calibrated
                if !self.quiet {
                    if let s = self.video.graySnapshot() {
                        self.appendLog("video: \(s.w)x\(s.h) live")
                    } else if self.state == "session" {
                        self.appendLog("video: no frames (\(self.video.chunks) chunks, turn on Screen Mirroring to the board)")
                    }
                }
                // No usable frame (lost GOP sync, or a still screen makes AirPlay go
                // quiet): 'snap' re-sends SPS/PPS plus the current GOP. This keeps
                // running while the UI is frozen for a pointer measurement.
                if self.state == "session", !self.video.isFresh, self.video.chunks > 0 {
                    try? self.session.sendCommand("snap")
                }
                // Chunks arrive but every access unit is rejected: the stream started
                // mid-GOP or lost frames, so restart it and take a fresh keyframe.
                if self.state == "session", self.video.decodeErrors != self.lastDecodeErrors {
                    self.lastDecodeErrors = self.video.decodeErrors
                    try? self.session.sendCommand("stream off")
                    try? self.session.sendCommand("stream on")
                    try? self.session.sendCommand("snap")
                    if !self.quiet { self.appendLog("video: resync (stream off/on + snap)") }
                }
            }
        }
    }

    func appendLog(_ s: String) {
        Task { @MainActor in
            if self.quiet {
                self.quietBuffer.append(s)
                return
            }
            let line = "\(DateFormatter.localizedString(from: Date(), dateStyle: .none, timeStyle: .medium)) \(s)"
            self.log.append(line)
            if self.log.count > 300 { self.log.removeFirst(self.log.count - 300) }
        }
    }

    func connect() {
        if !autoPilot { startAuto(); return }
        link.start()
        lastScanStart = Date()
        appendLog("scanning for ESP32 Agent ...")
    }

    func openSession() {
        Task {
            do {
                try await session.open()
                try await session.sendCommand("stream on")
                appendLog("video stream requested")
                // A stream that starts mid-GOP carries no SPS/PPS, so ask for the
                // current GOP (snap = SPS/PPS + every AU since the last IDR).
                try await session.sendCommand("snap")
                appendLog("video: asked for the current GOP (snap)")
            } catch {
                appendLog("open failed: \(error)")
            }
        }
    }

    func pair() {
        Task {
            do {
                try await session.pair()
                appendLog("paired! tap Open session next")
            } catch {
                appendLog("pair failed: \(error)")
            }
        }
    }

    func unpair() {
        let id = UserDefaults.standard.string(forKey: "lastBoardID") ?? ""
        UserDefaults.standard.removeObject(forKey: "K.\(id)")
        appendLog("forgot board key; power-cycle the board and Pair again")
    }

    func calibrate() {
        Task {
            do {
                try await pointer.calibrate()
                self.calibrated = pointer.calibrated
            } catch {
                appendLog("calibration failed: \(error)")
            }
        }
    }

    func verifyPointer() {
        Task {
            quiet = true
            defer {
                quiet = false
                let buffered = quietBuffer
                quietBuffer.removeAll()
                for line in buffered { appendLog(line) }
            }
            do {
                try await pointer.verifyMapping()
            } catch {
                appendLog("pointer check failed: \(error)")
            }
        }
    }

    func loadModel() {
        Task {
            llm.onLog = { self.appendLog($0) }
            do {
                try llm.load()
                await MainActor.run { self.modelReady = true }
            } catch {
                appendLog("model failed: \(error)")
            }
        }
    }

    func applyLoopConfig() {
        loop.config.headFollow = headFollow
        loop.config.agentMode = agentMode
        loop.config.goal = goal
    }

    func startLoop() {
        applyLoopConfig()
        loop.start()
        appendLog("loop: head-follow=\(headFollow), agent=\(agentMode)")
    }

    func stopLoop() {
        loop.stop()
        appendLog("loop stopped")
    }

    func loopOn() -> Bool { loop.running }
}

@main
struct ScreenAgentApp: App {
    var body: some Scene {
        WindowGroup { ContentView() }
    }
}
