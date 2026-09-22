import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let synthesizer = AVSpeechSynthesizer()
  private var speechDelegate: SpeechSynthesizerDelegate?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    let channel = FlutterMethodChannel(
      name: "voice_loop/tts",
      binaryMessenger: engineBridge.applicationRegistrar.messenger())

    let delegate = SpeechSynthesizerDelegate(channel: channel)
    synthesizer.delegate = delegate
    self.speechDelegate = delegate

    channel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "speak":
        let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
        // speech_to_text leaves AVAudioSession in a record-oriented category
        // after listening. Without forcing .playback here, AVSpeechSynthesizer
        // speaks into that stale session and produces no audible sound (no
        // error either, since the call itself doesn't fail) — this is what
        // was silent on-device despite STT working.
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .default)
        try? AVAudioSession.sharedInstance().setActive(true)
        let utterance = AVSpeechUtterance(string: text)
        utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
        self.synthesizer.speak(utterance)
        result(nil)
      case "stop":
        self.synthesizer.stopSpeaking(at: .immediate)
        result(nil)
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

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didFinish utterance: AVSpeechUtterance) {
    channel.invokeMethod("onComplete", arguments: nil)
  }

  func speechSynthesizer(_ synthesizer: AVSpeechSynthesizer, didCancel utterance: AVSpeechUtterance) {
    channel.invokeMethod("onComplete", arguments: nil)
  }
}
