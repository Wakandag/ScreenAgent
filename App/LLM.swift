import Foundation
import llama

/// On-device LLM planner (llama.cpp, CPU, Qwen2.5-0.5B Q4 bundled in the IPA).
/// Free, offline, no API keys.
final class LLM {
    private var model: OpaquePointer?
    private var ctx: OpaquePointer?
    private(set) var loaded = false
    var onLog: ((String) -> Void)?
    private let lock = NSLock()

    func load() throws {
        guard !loaded else { return }
        guard let url = Self.modelURL() else {
            throw NSError(domain: "llm", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "model.gguf not found in the bundle"])
        }
        onLog?("loading model \(url.lastPathComponent) ...")
        var mparams = llama_model_default_params()
        mparams.n_gpu_layers = 0                     // CPU only; Metal stays off for build simplicity
        guard let m = llama_model_load_from_file(url.path, mparams) else {
            throw NSError(domain: "llm", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "llama_model_load_from_file failed"])
        }
        model = m
        var cparams = llama_context_default_params()
        cparams.n_ctx = 2048
        cparams.n_batch = 256
        cparams.n_threads = 4
        cparams.n_threads_batch = 4
        guard let c = llama_init_from_model(m, cparams) else {
            llama_model_free(m)
            model = nil
            throw NSError(domain: "llm", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "llama_init_from_model failed"])
        }
        ctx = c
        loaded = true
        onLog?("model ready")
    }

    static func modelURL() -> URL? {
        if let u = Bundle.main.url(forResource: "model", withExtension: "gguf") { return u }
        return Bundle.main.url(forResource: "model", withExtension: "gguf", subdirectory: "Resources")
    }

    func unload() {
        lock.lock()
        defer { lock.unlock() }
        if let c = ctx { llama_free(c) }
        if let m = model { llama_model_free(m) }
        ctx = nil; model = nil
        loaded = false
    }

    /// ChatML (Qwen). Returns the assistant text, cut at <|im_end|>.
    func chat(system: String, user: String, maxTokens: Int = 140) -> String {
        lock.lock()
        defer { lock.unlock() }
        guard let model, let ctx else { return "" }
        let vocab = llama_model_get_vocab(model)
        let prompt = "<|im_start|>system\n\(system)<|im_end|>\n<|im_start|>user\n\(user)<|im_end|>\n<|im_start|>assistant\n"
        let tokens = Self.tokenize(vocab, prompt)
        let nprompt = tokens.count
        guard nprompt > 0, nprompt < 2048 else { return "" }

        // prefill in chunks; the logits of a batch land on its last token
        var chunk: [llama_token] = []
        var i = 0
        var logitsIdx: Int32 = 0
        while i < nprompt {
            let take = min(64, nprompt - i)
            chunk = Array(tokens[i..<i+take])
            var b = llama_batch_get_one(&chunk, Int32(take))
            if llama_decode(ctx, b) != 0 { return "" }
            logitsIdx = Int32(take - 1)
            i += take
        }

        // greedy generate
        var out = ""
        let nVocab = Int32(llama_vocab_n_tokens(vocab))
        var logits = [Float](repeating: 0, count: Int(nVocab))
        var piece = [CChar](repeating: 0, count: 64)
        var token: llama_token = -1
        var generated = 0
        while generated < maxTokens {
            if token >= 0 {
                var one: [llama_token] = [token]
                var b = llama_batch_get_one(&one, 1)
                if llama_decode(ctx, b) != 0 { break }
                logitsIdx = 0
            }
            guard let lp = llama_get_logits_ith(ctx, logitsIdx) else { break }
            logits.withUnsafeMutableBufferPointer { lb in
                memcpy(lb.baseAddress!, lp, Int(nVocab) * MemoryLayout<Float>.size)
            }
            var best: llama_token = 0
            var bestVal: Float = -Float.infinity
            for t in 0..<Int(nVocab) where logits[t] > bestVal {
                bestVal = logits[t]; best = llama_token(t)
            }
            token = best
            if token < 0 || token >= nVocab { break }
            let n = llama_token_to_piece(vocab, token, &piece, 63, 0, true)
            if n <= 0 { break }
            out += String(decoding: piece[0..<Int(n)].map { UInt8(bitPattern: $0) }, as: UTF8.self)
            generated += 1
            if out.contains("<|im_end|>") || out.contains("<|im_start|>") {
                out = out.replacingOccurrences(of: "<|im_end|>", with: "")
                    .replacingOccurrences(of: "<|im_start|>", with: "")
                break
            }
        }
        return out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// String → tokens via a CChar buffer (llama_tokenize wants `char *`).
    static func tokenize(_ vocab: OpaquePointer?, _ s: String) -> [llama_token] {
        let n = s.utf8.count
        guard n > 0 else { return [] }
        var cs = [CChar](repeating: 0, count: n + 1)
        s.withCString { src in
            strncpy(&cs, src, n)
        }
        let ntok = llama_tokenize(vocab, cs, Int32(n), nil, 0, false, true)
        guard ntok > 0 else { return [] }
        var toks = [llama_token](repeating: 0, count: Int(ntok))
        _ = llama_tokenize(vocab, cs, Int32(n), &toks, ntok, false, true)
        return toks
    }

    // MARK: Action prompt

    static let systemPrompt = """
    You control an iPhone through a Bluetooth mouse connected to a small board. You see the text of the current screen. Reply with exactly ONE JSON line, no prose, choosing one action:
    {"action":"tap","x":0.0,"y":0.0}
    {"action":"swipe","x1":0.0,"y1":0.0,"x2":0.0,"y2":0.0}
    {"action":"text","text":"ascii only"}
    {"action":"key","key":"enter|backspace|esc|tab"}
    {"action":"home"}
    {"action":"wait"}
    {"action":"done"}
    x,y are fractions of the screen, 0.0..1.0, y=0 is the TOP. Choose the smallest action that makes progress toward the GOAL. If the screen already satisfies the goal, reply {"action":"done"}.
    """

    /// Parse the model's reply into a decodable action; nil if unusable.
    static func parse(_ text: String) -> [String: Any]? {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("```") {
            s = s.replacingOccurrences(of: "```json", with: "").replacingOccurrences(of: "```", with: "")
            s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        guard let start = s.firstIndex(of: "{"), let end = s.lastIndex(of: "}"), start < end else { return nil }
        let json = s[start...end]
        return try? JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any]
    }
}
