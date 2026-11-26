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

    init() {
        session.outbound = { [weak self] frame in
            try? self?.link.write(frame)
        }
        link.onFrame = { [weak self] frame in
            self?.session.feed(frame)
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
                guard let self, self.frameImage == nil || Int.random(in: 0..<15) == 0 else { return }
                self.frameImage = self.video.uiImage()
            }
        }
        loop.onLog = { [weak self] in self?.appendLog($0) }
        startStatusTimer()
        startAuto()
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
        guard state != "session" else { return }
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
                if let s = self.video.graySnapshot() {
                    self.appendLog("video: \(s.w)x\(s.h) live")
                } else if self.state == "session" {
                    self.appendLog("video: no frames (turn on Screen Mirroring to the board)")
                }
            }
        }
    }

    func appendLog(_ s: String) {
        Task { @MainActor in
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
