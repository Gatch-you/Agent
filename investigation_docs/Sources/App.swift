import SwiftUI

@main
struct VoiceLoopLabApp: App {
    var body: some Scene {
        WindowGroup {
            if #available(iOS 26.0, *) {
                ContentView()
            } else {
                Text("iOS 26 以降が必要です")
            }
        }
    }
}

@available(iOS 26.0, *)
struct ContentView: View {
    @State private var loop = VoiceLoop()

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    stateHeader
                    controls
                    metrics
                    transcript
                    logView
                }
                .padding()
            }
            .navigationTitle("Voice Loop Lab")
        }
        .task {
            // VoiceLoop（音声ループ）とは無関係に、起動時に一度だけ
            // FoundationModels が英語テキストで使えるかを確認する。
            let result = await FoundationModelsCheck.run()
            print(result)
        }
        .task {
            // 画面操作なしで Mac から切り分けを回すための起動引数。
            // 例: devicectl ... launch --console <bundle id> -- -sttLocale fr-FR -installBeforeAudio YES -legacyProbe YES -autoStart YES
            let d = UserDefaults.standard
            if let id = d.string(forKey: "sttLocale") { loop.sttLocaleID = id }
            if d.object(forKey: "installBeforeAudio") != nil {
                loop.installAssetsBeforeAudio = d.bool(forKey: "installBeforeAudio")
            }
            if d.object(forKey: "releaseReservations") != nil {
                loop.releaseReservationsBeforeInstall = d.bool(forKey: "releaseReservations")
            }
            if d.object(forKey: "legacyProbe") != nil {
                loop.probeLegacyOnDevice = d.bool(forKey: "legacyProbe")
            }
            if let e = d.string(forKey: "sttEngine").flatMap(Transcriber.Engine.init(rawValue:)) {
                loop.sttEngine = e
            }
            if d.object(forKey: "transcribeOnly") != nil {
                loop.transcribeOnly = d.bool(forKey: "transcribeOnly")
            }
            if d.bool(forKey: "autoStart") { await loop.startSession() }
            if d.bool(forKey: "sttSelfTest"), loop.state == .listening {
                await loop.runSTTSelfTest()
            }
        }
    }

    // MARK: -

    private var stateHeader: some View {
        HStack(spacing: 12) {
            Circle()
                .fill(color(for: loop.state))
                .frame(width: 12, height: 12)
            Text(loop.state.rawValue)
                .font(.system(.title3, design: .monospaced))
                .bold()
            Spacer()
            Text(String(format: "%.0f dB", loop.liveRMSdB))
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
        }
    }

    private var controls: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Button {
                    Task { await loop.startSession() }
                } label: {
                    Label("開始", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .disabled(loop.state != .idle && loop.state != .failed)

                Button {
                    Task { await loop.stopSession() }
                } label: {
                    Label("停止", systemImage: "stop.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.bordered)
                .disabled(loop.state == .idle)
            }

            Button {
                Task { await loop.runAECTest() }
            } label: {
                Label("AEC 検証（話さずに待つ）", systemImage: "waveform.badge.exclamationmark")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .disabled(loop.state != .listening)

            Toggle(isOn: Binding(
                get: { loop.transcribeOnly },
                set: { loop.transcribeOnly = $0 }
            )) {
                Text("文字起こしのみ（応答を挟まず全部テキスト化）")
                    .font(.caption)
            }

            sttDiagnostics
        }
    }

    /// en-US のアセットインストールが固まる原因の切り分け用。
    /// セッション開始前に設定する（開始後の変更は次回の開始から効く）。
    private var sttDiagnostics: some View {
        GroupBox("STT 切り分け") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("エンジン", selection: Binding(
                    get: { loop.sttEngine },
                    set: { loop.sttEngine = $0 }
                )) {
                    Text("SpeechTranscriber").tag(Transcriber.Engine.speech)
                    Text("DictationTranscriber").tag(Transcriber.Engine.dictation)
                }
                .pickerStyle(.segmented)

                Picker("ロケール", selection: Binding(
                    get: { loop.sttLocaleID },
                    set: { loop.sttLocaleID = $0 }
                )) {
                    ForEach(["en-US", "en-GB", "ja-JP", "fr-FR", "de-DE", "ko-KR"], id: \.self) {
                        Text($0).tag($0)
                    }
                }
                .pickerStyle(.menu)

                Toggle(isOn: Binding(
                    get: { loop.installAssetsBeforeAudio },
                    set: { loop.installAssetsBeforeAudio = $0 }
                )) {
                    Text("音声エンジン起動前にアセットをインストール")
                        .font(.caption)
                }
            }
            .disabled(loop.state != .idle && loop.state != .failed)
        }
    }

    private var metrics: some View {
        GroupBox("計測") {
            VStack(alignment: .leading, spacing: 6) {
                row("Voice Processing", loop.voiceProcessingEnabled ? "有効" : "無効")
                row("入力フォーマット", loop.inputFormatDescription)
                if let v = loop.aecVerdict {
                    Divider()
                    Text(v)
                        .font(.system(.caption, design: .monospaced))
                        .foregroundStyle(v.contains("疑い") ? .red : .green)
                }
                Divider()
                Text(loop.ttsReport)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var transcript: some View {
        GroupBox("認識結果") {
            VStack(alignment: .leading, spacing: 6) {
                Text(loop.finalizedText.isEmpty ? "—" : loop.finalizedText)
                if !loop.volatileText.isEmpty {
                    Text(loop.volatileText).foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logView: some View {
        GroupBox("ログ") {
            VStack(alignment: .leading, spacing: 3) {
                ForEach(Array(loop.log.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack {
            Text(k).font(.caption).foregroundStyle(.secondary)
            Spacer()
            Text(v).font(.system(.caption, design: .monospaced))
        }
    }

    private func color(for s: VoiceLoop.State) -> Color {
        switch s {
        case .idle:      return .gray
        case .preparing: return .orange
        case .listening: return .green
        case .thinking:  return .blue
        case .speaking:  return .purple
        case .failed:    return .red
        }
    }
}
