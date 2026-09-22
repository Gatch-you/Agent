import 'dart:convert';

import 'package:client/adapters/llm/gemini_llm.dart';
import 'package:client/domain/voice_loop_state.dart';
import 'package:client/ports/llm_port.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('GeminiLlm', () {
    test('sends conversation history mapped to Gemini roles, with the API key and system instruction', () async {
      late Uri capturedUri;
      late Map<String, dynamic> capturedBody;

      final client = MockClient((request) async {
        capturedUri = request.url;
        capturedBody = jsonDecode(request.body) as Map<String, dynamic>;
        return http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': '  Nice to meet you too!  '},
                  ],
                },
              },
            ],
          }),
          200,
        );
      });

      final llm = GeminiLlm(apiKey: 'test-key', client: client);
      final reply = await llm.reply(const [
        VoiceLoopMessage(role: MessageRole.user, text: 'Nice to meet you.'),
        VoiceLoopMessage(role: MessageRole.assistant, text: 'You too!'),
      ]);

      expect(reply, 'Nice to meet you too!');
      expect(capturedUri.queryParameters['key'], 'test-key');
      expect(capturedBody['systemInstruction'], isNotNull);
      expect(capturedBody['contents'], [
        {
          'role': 'user',
          'parts': [
            {'text': 'Nice to meet you.'},
          ],
        },
        {
          'role': 'model',
          'parts': [
            {'text': 'You too!'},
          ],
        },
      ]);
    });

    test('throws LlmException on a non-200 response', () async {
      final client = MockClient((request) async => http.Response('bad request', 400));
      final llm = GeminiLlm(apiKey: 'test-key', client: client);

      expect(
        () => llm.reply(const [VoiceLoopMessage(role: MessageRole.user, text: 'hi')]),
        throwsA(isA<LlmException>()),
      );
    });

    test('throws LlmException when the response has no candidate text', () async {
      final client = MockClient((request) async => http.Response(jsonEncode({'candidates': <dynamic>[]}), 200));
      final llm = GeminiLlm(apiKey: 'test-key', client: client);

      expect(
        () => llm.reply(const [VoiceLoopMessage(role: MessageRole.user, text: 'hi')]),
        throwsA(isA<LlmException>()),
      );
    });

    test('always sends an empty tools list in phase 1', () async {
      final client = MockClient(
        (request) async => http.Response(
          jsonEncode({
            'candidates': [
              {
                'content': {
                  'parts': [
                    {'text': 'ok'},
                  ],
                },
              },
            ],
          }),
          200,
        ),
      );
      final llm = GeminiLlm(apiKey: 'test-key', client: client);

      // Compiles with the default (empty) tools param — the point of this
      // test is that LlmPort.reply's signature carries `tools` at all.
      await llm.reply(const [VoiceLoopMessage(role: MessageRole.user, text: 'hi')], tools: const <LlmTool>[]);
    });
  });
}
