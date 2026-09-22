import 'package:client/adapters/stt/dictation_transcriber_stt.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('voice_loop/stt');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  late List<MethodCall> calls;
  late DictationTranscriberStt stt;

  void mockNative(dynamic Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  Future<void> simulateNativeCall(String method, [dynamic arguments]) {
    final data = channel.codec.encodeMethodCall(MethodCall(method, arguments));
    return messenger.handlePlatformMessage(channel.name, data, (_) {});
  }

  setUp(() {
    calls = [];
    stt = DictationTranscriberStt();
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
  });

  test('initialize resolves true when native returns true', () async {
    mockNative((call) => true);

    final result = await stt.initialize();

    expect(result, isTrue);
    expect(calls.single.method, 'initialize');
  });

  test('initialize resolves false when native returns false', () async {
    mockNative((call) => false);

    final result = await stt.initialize();

    expect(result, isFalse);
  });

  test('startListening invokes native startListening', () async {
    mockNative((call) => null);

    await stt.startListening(onPartialResult: (_) {}, onFinalResult: (_) {});

    expect(calls.single.method, 'startListening');
  });

  test('native onPartialResult invokes the onPartialResult callback', () async {
    mockNative((call) => null);
    String? received;

    await stt.startListening(
      onPartialResult: (text) => received = text,
      onFinalResult: (_) {},
    );
    await simulateNativeCall('onPartialResult', {'text': 'hello wor'});

    expect(received, 'hello wor');
  });

  test('native onFinalResult invokes the onFinalResult callback', () async {
    mockNative((call) => null);
    String? received;

    await stt.startListening(
      onPartialResult: (_) {},
      onFinalResult: (text) => received = text,
    );
    await simulateNativeCall('onFinalResult', {'text': 'hello world'});

    expect(received, 'hello world');
  });

  test('stopListening invokes native stopListening', () async {
    mockNative((call) => null);

    await stt.stopListening();

    expect(calls.single.method, 'stopListening');
  });

  test('dispose invokes native dispose', () async {
    mockNative((call) => null);

    await stt.dispose();

    expect(calls.single.method, 'dispose');
  });
}
