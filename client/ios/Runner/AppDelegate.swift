import AVFoundation
import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private let kokoroBridge = KokoroTtsBridge()

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

    ttsChannel.setMethodCallHandler { [weak self] call, result in
      guard let self else { return }
      switch call.method {
      case "speak":
        let text = (call.arguments as? [String: Any])?["text"] as? String ?? ""
        Task {
          // No AVAudioSession category switch here on purpose:
          // DictationTranscriberBridge's STT session runs continuously for
          // the whole conversation (see its type doc) on .playAndRecord,
          // which already supports simultaneous playback — KokoroTtsBridge
          // just renders into that already-active session. This relies on
          // STT having started at least once before the first reply is
          // spoken, which the app's flow (STT always runs first; TTS only
          // ever replies to a recognized turn) guarantees.
          do {
            try await self.kokoroBridge.speak(text)
          } catch {
            print("[TTS] Kokoro speak failed: \(error)")
          }
          ttsChannel.invokeMethod("onComplete", arguments: nil)
        }
        result(nil)
      case "stop":
        Task { await self.kokoroBridge.stop() }
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
