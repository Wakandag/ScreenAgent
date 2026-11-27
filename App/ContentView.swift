import SwiftUI

struct ContentView: View {
    @StateObject private var vm = AgentViewModel()

    var body: some View {
        NavigationView {
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    boardSection
                    screenSection
                    controlsSection
                    logSection
                }
                .padding()
            }
            .navigationTitle("ScreenAgent")
        }
    }

    private var boardSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Board").font(.headline)
                    Spacer()
                    Text(vm.state).foregroundColor(.secondary)
                }
                HStack {
                    Button("Connect") { vm.connect() }
                    Button("Open session") { vm.openSession() }
                    Button("Pair") { vm.pair() }
                    Button("Forget", role: .destructive) { vm.unpair() }
                }
                if !vm.boardStatus.isEmpty {
                    Text(vm.boardStatus).font(.caption2).foregroundColor(.secondary)
                }
                Text("Connects automatically over Bluetooth; the phone's bond with the board is the pairing.").font(.caption).foregroundColor(.blue)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var screenSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 8) {
                Text("Mirrored screen").font(.headline)
                if let img = vm.frameImage {
                    Image(uiImage: img)
                        .resizable()
                        .scaledToFit()
                        .frame(maxHeight: 220)
                        .cornerRadius(8)
                } else {
                    Text("no frame yet — turn on Screen Mirroring (AirPlay) to the board").font(.caption).foregroundColor(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var controlsSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Button("Calibrate pointer") { vm.calibrate() }
                    Text(vm.calibrated ? "calibrated" : "not calibrated")
                        .font(.caption).foregroundColor(vm.calibrated ? .green : .orange)
                }
                Button("Verify pointer") { vm.verifyPointer() }
                Toggle("Head-follow (keep head centered)", isOn: $vm.headFollow)
                Toggle("Agent mode (on-device LLM acts)", isOn: $vm.agentMode)
                TextField("Goal", text: $vm.goal)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Button("Start loop") { vm.startLoop() }
                    Button("Stop loop") { vm.stopLoop() }
                    Button(vm.modelReady ? "Model loaded" : "Load model") { vm.loadModel() }
                        .disabled(vm.modelReady)
                }
                Text("Head-follow uses the built-in face detector. Agent mode runs the bundled 0.5B model locally — no network, no keys. Typing is ASCII only.").font(.caption).foregroundColor(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logSection: some View {
        GroupBox {
            VStack(alignment: .leading, spacing: 4) {
                Text("Log").font(.headline)
                let lines = Array(vm.log.suffix(40).reversed())
                ForEach(lines.indices, id: \.self) { i in
                    Text(lines[i]).font(.system(size: 11, design: .monospaced))
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
