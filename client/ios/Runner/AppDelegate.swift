import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var speechDelegate: SpeechSynthesizerDelegate?

  // Type-erased so this property can exist on a class that must support
  // pre-iOS-26 deployment targets; DictationTranscriberBridge itself
  // requires @available(iOS 26.0, *).
  private var sttBridgeBox: Any?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let ttsChannel = FlutterMethodChannel(
      name: "voice_loop/tts",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())

    let delegate = SpeechSynthesizerDelegate(channel: ttsChannel)
    synthesizer.delegate = delegate
    self.speechDelegate = delegate

    ttsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "speak":
        let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
        // No category switch here on purpose: DictationTranscriberBridge's
        // STT session runs continuously for the whole conversation (see its
        // type doc) on .playAndRecord, which already supports simultaneous
        // playback. Switching to .playback here would have disrupted that
        // already-running engine. This relies on STT having started at least
        // once before the first reply is spoken, which the app's flow (STT
        // always runs first; TTS only ever replies to a recognized turn)
        // guarantees.
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        print("[TTS] speak: \"\(text)\" category=\(AVAudioSession.sharedInstance().category.rawValue) isSpeaking=\(self.synthesizer.isSpeaking)")
        self.synthesizer.speak(utterance)
        result(nil)
      case "stop":
        self.synthesizer.stopSpeaking(at: .immediate)
        result(nil)
      default:
        result(FlutterMethodNotImplemented)
      }
    }

    let sttChannel = FlutterMethodChannel(
      name: "voice_loop/stt",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())

    sttChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      guard #available(iOS 26.0, *) else {
        result(call.method == "initialize" ? false : nil)
        return
      }

      let bridge: DictationTranscriberBridge
      if let existing = self.sttBridgeBox as? DictationTranscriberBridge {
        bridge = existing
      } else {
        bridge = DictationTranscriberBridge()
        self.sttBridgeBox = bridge
      }

      switch call.method {
      case "initialize":
        Task {
          let available = await bridge.initialize()
          result(available)
        }
      case "startListening":
        Task {
          do {
            try await bridge.startListening(
              onPartial: { text in
                DispatchQueue.main.async {
                  sttChannel.invokeMethod("onPartialResult", arguments: ["text": text])
                }
              },
              onFinal: { text in
                DispatchQueue.main.async {
                  sttChannel.invokeMethod("onFinalResult", arguments: ["text": text])
                }
              }
            )
            result(nil)
          } catch {
            result(FlutterError(code: "start_listening_failed", message: error.localizedDescription, details: nil))
          }
        }
      case "stopListening":
        Task {
          await bridge.stopListening()
          result(nil)
        }
      case "dispose":
        Task {
          await bridge.dispose()
          result(nil)
        }
      default:
        result(FlutterMethodNotImplemented)
      }
    }
  }
}

/// Bridges `AVSpeechSynthesizer`'s completion callback back to Dart. This is
/// the walking-skeleton TTS bridge (`.claude/specs/voice-loop-walking-skeleton.md`)
/// — a minimal precursor to the real on-device Kokoro-82M platform channel
/// (design doc §09), using only the OS's own AVFoundation, no CocoaPods/SPM
/// third-party dependency required.
private class SpeechSynthesizerDelegate: NSObject, AVSpeechSynthesizerDelegate {
  private let channel: FlutterMethodChannel

  init(channel: FlutterMethodChannel) {
    self.channel = channel
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didStart utterance: AVSpeechUtterance) {
    print("[TTS] didStart")
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    print("[TTS] didFinish")
    channel.invokeMethod("onComplete", arguments: nil)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    print("[TTS] didCancel")
    channel.invokeMethod("onComplete", arguments: nil)
  }
}
