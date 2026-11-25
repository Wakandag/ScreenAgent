# ScreenAgent — on-device head-following + LLM agent for the ESP32 iPhone Agent board

An unsigned .ipa built for **iOS 16.4+ (iPhone 13 Pro Max, iOS 16.6.1, TrollStore)**.
It talks to the ESP32-S3 "ESP32 Agent" board over BLE (the board's documented CLI
protocol), receives the AirPlay screen mirroring, and can:

- **Head-follow mode** — keeps the human head on screen centered by swiping (free, instant, uses Apple's built-in face detector).
- **Agent mode** — a bundled, fully offline **Qwen2.5-0.5B-Instruct Q4** model (llama.cpp, CPU) reads the screen text (OCR) and issues taps/swipes/keys to drive the phone toward a goal you type. No network, no API keys, free.

## What you do (one-time)

1. **Fork** `onehumanbeing/esp32-iphone-agent`-style: actually simpler — create an empty GitHub repo, copy this `agentipa/` folder's contents into it (including `.github/`), push.
2. On GitHub: **Actions → Build IPA → Run workflow**. Wait ~10–15 min (llama.cpp compiles + 400 MB model downloads).
3. Download the `ScreenAgent-ipa` artifact → unzip → you get `ScreenAgent.ipa`.
4. AirDrop/send the .ipa to the iPhone and install it with **TrollStore** (it installs unsigned IPAs permanently on iOS 16.6.1).
5. **Power-cycle the board** (unplug from the iPhone, wait 3 s, replug). Within 3 minutes:
6. In ScreenAgent: tap **Connect** → **Pair** → **Open session**.
7. Start Screen Mirroring (AirPlay) on the iPhone to the board, then tap **Calibrate pointer** once.
8. Toggle **Head-follow** and/or **Agent mode**, type a goal, tap **Start loop**.

## Notes

- The board pairs **only within 3 minutes of power-on** — that's the firmware's rule, not a bug.
- Agent mode needs the pointer calibrated for taps; head-follow needs calibrated swipes.
- The board's `text` command types **ASCII only**.
- The app runs in the background (Bluetooth background mode is enabled in the plist).
- Everything is open protocol: `docs/cli-protocol.md` in the upstream repo (X25519 pairing → HKDF → AES-128-GCM DATA frames → H.264 video).
- If you also want to run the PC CLI at the same time, both connections can coexist (separate services).

## Build troubleshooting

- If the workflow fails on llama.cpp options, check `Scripts/build-llama.sh` — the pin is `v1.0.0`.
- The model URL is in `Scripts/fetch-model.sh` (any small Qwen/Llama GGUF works; keep it ≤ ~1 GB for the 6 GB device).
- First build is ~10–15 min; reruns reuse nothing ( runners are ephemeral) — push a tag to rebuild.

## Layout

- `App/` — Swift app (BLE link, protocol crypto, video pipe, Vision, pointer, LLM, agent loop, UI)
- `headers/` — modulemap for `import llama`
- `Scripts/build-llama.sh` — builds llama.cpp static libs for iOS (CPU only)
- `Scripts/fetch-model.sh` — downloads the bundled GGUF
- `.github/workflows/build-ipa.yml` — the whole pipeline
