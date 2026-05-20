//.title
// ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
//
// Copyright © dev-cetera.com & contributors.
//
// The use of this source code is governed by an MIT-style license described in
// the LICENSE file located in this project's root directory.
//
// See: https://opensource.org/license/mit
//
// ▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓▓
//.title~

import '/_common.dart';

/// Vendor-neutral AI broker. One implementation per provider (Claude,
/// OpenAI, Gemini). Callers depend on this interface; the [AiBrokerRegistry]
/// is the indirection that lets the active provider change at runtime.
///
/// API keys arrive per-call. Storage is the caller's problem — either
/// pass them directly (Flutter apps that already own a SecureStore) or
/// resolve them through a [KeyResolver] (CLI / backend).
abstract class AiBroker {
  /// Stable identifier — `'openai'`, `'anthropic'`, `'gemini'`. Used as
  /// the key in [AiBrokerRegistry] and as the [KeyResolver] lookup id.
  String get id;

  /// Human label for picker UIs. `'OpenAI'`, `'Anthropic (Claude)'`,
  /// `'Google (Gemini)'`.
  String get label;

  /// Models suitable for chat / completion, newest first. Returns an
  /// empty list for an unset / invalid key. Each provider filters out
  /// embeddings / vision / audio-only models so the dropdown isn't
  /// flooded with irrelevant entries.
  Future<List<String>> listModels(String apiKey);

  /// Single-shot. Returns the assistant's raw text.
  Future<String> complete({
    required String apiKey,
    required String model,
    required String system,
    required String user,
    double temperature = 0.3,
    int maxTokens = 2048,
  }) =>
      chat(
        apiKey: apiKey,
        model: model,
        request: ChatRequest.single(
          system: system,
          user: user,
          temperature: temperature,
          maxTokens: maxTokens,
        ),
      );

  /// Multi-turn. Returns the assistant's raw text for the final turn.
  Future<String> chat({
    required String apiKey,
    required String model,
    required ChatRequest request,
  });

  /// Token-streaming chat. Each event is an *incremental* delta —
  /// concatenating every event yields the same string [chat] would
  /// return. Closes the stream cleanly on end-of-message; errors are
  /// surfaced via the stream.
  Stream<String> stream({
    required String apiKey,
    required String model,
    required ChatRequest request,
  });
}

/// Process-wide registry. Wire brokers once at startup, then look them
/// up by [AiBroker.id] from anywhere in the app.
///
/// Mirrors the registry shape from powerdb (`lib/ai/provider.dart`) so
/// migrating existing call sites is a one-line rename.
class AiBrokerRegistry {
  AiBrokerRegistry._();
  static final AiBrokerRegistry instance = AiBrokerRegistry._();

  final Map<String, AiBroker> _brokers = {};

  void register(AiBroker broker) {
    _brokers[broker.id] = broker;
  }

  void unregister(String id) {
    _brokers.remove(id);
  }

  AiBroker? lookup(String id) => _brokers[id];

  List<AiBroker> get all => List.unmodifiable(_brokers.values);

  void clear() => _brokers.clear();
}

/// Thrown for any broker-layer failure that callers can present to the
/// user — auth, rate-limit-after-retries, empty response, malformed
/// response.
class AiBrokerException implements Exception {
  final String message;
  final int? statusCode;
  const AiBrokerException(this.message, {this.statusCode});

  @override
  String toString() =>
      statusCode == null ? message : 'HTTP $statusCode: $message';
}
