import FoundationModels
import Foundation

/// SpeechAnalyzer と同じ「Apple Intelligence」系APIである FoundationModels が、
/// この端末（日本リージョン）で英語テキストを扱えるかを確認するための、
/// 独立した最小限のチェック。VoiceLoop の状態機械とは無関係に、
/// アプリ起動時に一度だけ実行する。
@available(iOS 26.0, *)
enum FoundationModelsCheck {
    static func run() async -> String {
        let model = SystemLanguageModel.default
        var log = "[FoundationModels] availability: \(model.availability)"

        guard case .available = model.availability else {
            return log
        }

        do {
            let session = LanguageModelSession()
            let t0 = Date()
            let response = try await session.respond(
                to: "Summarize this sentence in under 8 words: The quick brown fox jumps over the lazy dog near the riverbank."
            )
            let elapsed = Date().timeIntervalSince(t0)
            log += "\n[FoundationModels] response (\(String(format: "%.2f", elapsed))s): \(response.content)"
        } catch {
            log += "\n[FoundationModels] error: \(error.localizedDescription)"
        }
        return log
    }
}
