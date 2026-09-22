import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../domain/voice_loop_state.dart';
import '../../ports/llm_port.dart';

/// Thrown when the Gemini API returns a non-200 response, or a 200 with no
/// usable reply text.
class LlmException implements Exception {
  LlmException(this.message);

  final String message;

  @override
  String toString() => 'LlmException: $message';
}

/// [LlmPort] backed by Google's Gemini flash-class model, called via plain
/// HTTP REST (no SDK) — the provider/API-key-handling decisions here are
/// exactly what the user chose for this pass: Gemini Flash for speed/cost
/// (see `.claude/specs/gemini-llm-reply.md`), and the API key supplied via
/// `--dart-define` rather than secure storage (temporary, until a later
/// feature adds proper first-launch onboarding per `.claude/CLAUDE.md`).
class GeminiLlm implements LlmPort {
  GeminiLlm({required this.apiKey, http.Client? client, this.model = 'gemini-2.5-flash'})
    : _client = client ?? http.Client();

  final String apiKey;
  final String model;
  final http.Client _client;

  /// Establishes the assistant's actual Phase 1 purpose (`.claude/CLAUDE.md`'s
  /// Vision: "an English-speaking practice system") rather than a generic
  /// chatbot persona.
  static const _systemInstruction =
      'You are a friendly, encouraging English conversation partner helping '
      'the user practice spoken English. Keep replies short (1-3 sentences), '
      'natural, and conversational, like a real back-and-forth chat — not a '
      'lecture. Gently note significant grammar mistakes only when doing so '
      "would not interrupt the conversation's flow.";

  @override
  Future<String> reply(List<VoiceLoopMessage> history, {List<LlmTool> tools = const []}) async {
    final uri = Uri.parse(
      'https://generativelanguage.googleapis.com/v1beta/models/$model:generateContent?key=$apiKey',
    );

    final response = await _client.post(
      uri,
      headers: {'Content-Type': 'application/json'},
      body: jsonEncode({
        'systemInstruction': {
          'parts': [
            {'text': _systemInstruction},
          ],
        },
        'contents': history
            .map(
              (message) => {
                'role': message.role == MessageRole.user ? 'user' : 'model',
                'parts': [
                  {'text': message.text},
                ],
              },
            )
            .toList(),
      }),
    );

    if (response.statusCode != 200) {
      throw LlmException('Gemini request failed: ${response.statusCode} ${response.body}');
    }

    final decoded = jsonDecode(response.body);
    final candidates = decoded['candidates'] as List<dynamic>?;
    final parts = candidates?.isNotEmpty == true ? (candidates![0]?['content']?['parts'] as List<dynamic>?) : null;
    final text = parts?.isNotEmpty == true ? (parts![0]?['text'] as String?) : null;
    if (text == null || text.trim().isEmpty) {
      throw LlmException('Gemini returned no reply text: ${response.body}');
    }
    return text.trim();
  }
}
