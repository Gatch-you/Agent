import Foundation
import KokoroTTS

/// Kokoro-82M（CoreML / Neural Engine）による TTS + ベンチ計測。
///
/// 設計書 §09 検証ステップ3（実機での RTF・メモリ・ウォームアップ実測）を
/// ここで回収する。
///
/// 注意（公式ドキュメント記載の既知問題）:
///   一部の iOS 26 ビルドでは ANE コンパイラがこのモデルで不正な出力を出すことがある。
///   合成音が明らかに壊れている場合は `computeUnits: .cpuAndGPU` を試すこと。
actor TtsEngine {

    struct Sample: Sendable {
        let text: String
        let seconds: Double        // 生成された音声の長さ
        let elapsed: Double        // 生成にかかった時間
        var rtf: Double { seconds > 0 ? elapsed / seconds : .nan }
    }

    private var model: KokoroTTSModel?
    private(set) var warmupSeconds: Double = 0
    private(set) var samples: [Sample] = []

    /// モデルは `Resources/KokoroModel` としてアプリに同梱されており(約318MB)、
    /// ここから `offlineMode: true` で読み込む。HuggingFace への通信は発生しない。
    /// 同梱フォルダが無い場合（同梱し忘れたビルド等）は、フォールバックとして
    /// 従来通り HuggingFace から取得する。
    /// `onProgress` は `preparing` が「固まっているのか進んでいるのか」を
    /// 画面に出すために追加した（KokoroTTS 側は元々 progressHandler を持っている）。
    func load(bypassANE: Bool = false, onProgress: (@Sendable (Double, String) -> Void)? = nil) async throws {
        let t0 = CFAbsoluteTimeGetCurrent()
        let bundledModelDir = Bundle.main.resourceURL?.appendingPathComponent("KokoroModel")
        let useBundled = bundledModelDir.map { FileManager.default.fileExists(atPath: $0.path) } ?? false

        model = bypassANE
            ? try await KokoroTTSModel.fromPretrained(
                cacheDir: useBundled ? bundledModelDir : nil,
                offlineMode: useBundled,
                computeUnits: .cpuAndGPU,
                progressHandler: onProgress)
            : try await KokoroTTSModel.fromPretrained(
                cacheDir: useBundled ? bundledModelDir : nil,
                offlineMode: useBundled,
                progressHandler: onProgress)

        // ウォームアップ。初回推論は明らかに遅いので、
        // セッション開始時に1回空打ちしておく設計が本番でも必要になる。
        _ = try? synthesizeRaw("Warm up.", voice: "af_heart")
        warmupSeconds = CFAbsoluteTimeGetCurrent() - t0
    }

    /// 24 kHz mono Float32 を返す。
    func synthesize(_ text: String, voice: String = "af_heart") throws -> [Float] {
        let t0 = CFAbsoluteTimeGetCurrent()
        let audio = try synthesizeRaw(text, voice: voice)
        let elapsed = CFAbsoluteTimeGetCurrent() - t0
        samples.append(
            Sample(text: text, seconds: Double(audio.count) / 24_000.0, elapsed: elapsed)
        )
        return audio
    }

    private func synthesizeRaw(_ text: String, voice: String) throws -> [Float] {
        guard let model else { return [] }
        // ※ 引数ラベルは Xcode の補完で確認すること。
        //    speed を取る版もある: synthesize(text:voice:speed:)
        return try model.synthesize(text: text, voice: voice)
    }

    /// ベンチ結果のサマリ。
    /// 体感レイテンシは「最初の1文」で決まるので、短文の RTF が最も重要。
    func report() -> String {
        guard !samples.isEmpty else { return "（まだ計測なし）" }
        let rtfs = samples.map(\.rtf).filter { $0.isFinite }
        let mean = rtfs.reduce(0, +) / Double(rtfs.count)
        let worst = rtfs.max() ?? .nan
        return """
        ウォームアップ含むロード: \(String(format: "%.2f", warmupSeconds)) s
        合成回数: \(samples.count)
        RTF 平均: \(String(format: "%.3f", mean)) / 最悪: \(String(format: "%.3f", worst))
        ピークメモリ: \(String(format: "%.0f", MemoryProbe.peakMB())) MB
        """
    }

    func reset() { samples.removeAll() }
}

/// 実機のメモリ実測用。task_vm_info の phys_footprint を見る。
enum MemoryProbe {
    static func peakMB() -> Double {
        var info = task_vm_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
            }
        }
        guard kr == KERN_SUCCESS else { return 0 }
        return Double(info.phys_footprint) / 1024 / 1024
    }
}
