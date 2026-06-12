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

/// Base broker — every provider implements this. Capabilities (chat,
/// embed, translate, image, tts, …) live on **separate interfaces** in
/// per-modality folders (`lib/src/chat/`, `lib/src/embed/`,
/// `lib/src/translate/`, …). Concrete provider classes implement only
/// the capability interfaces their service actually supports.
///
/// Why split? An interface where most methods throw `UnsupportedError`
/// pushes runtime errors around for capability checks. The capability
/// split lets the type system enforce "you can only call `embed` on
/// something that's actually an `EmbedBroker`", which catches misuse at
/// compile time and makes "what does this provider support?" answerable
/// by reading the class declaration instead of grepping for throws.
///
/// **Breaking change in 0.3.0.** Pre-0.3, `chat` / `stream` / `complete`
/// / `embed` all lived on [AiBroker]. Now they live on `ChatBroker` /
/// `EmbedBroker`. Callers either upgrade their variable's declared
/// type (`ChatBroker broker = …`) or cast at the call site
/// (`(broker as EmbedBroker).embed(…)`). [AiBrokerRegistry.lookupAs]
/// gives a type-safe lookup that returns `null` when the broker doesn't
/// implement the requested capability.
abstract class AiBroker {
  /// Stable identifier — `'openai'`, `'anthropic'`, `'gemini'`,
  /// `'google_translate'`, … Used as the key in [AiBrokerRegistry] and
  /// as the `KeyResolver` lookup id.
  String get id;

  /// Human label for picker UIs. `'OpenAI'`, `'Anthropic (Claude)'`,
  /// `'Google (Gemini)'`, `'Google (Translate)'`.
  String get label;

  /// Models suitable for the broker's primary capability, newest
  /// first. Returns an empty list for an unset / invalid key, or for
  /// providers that have no user-selectable model (e.g. Google
  /// Translate v2).
  Future<List<String>> listModels(String apiKey);
}

/// Process-wide registry. Wire brokers once at startup, then look them
/// up by [AiBroker.id] from anywhere in the app.
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

  /// Untyped lookup. Returns the registered broker or null. Callers
  /// that need a specific capability should prefer [lookupAs].
  AiBroker? lookup(String id) => _brokers[id];

  /// Capability-typed lookup. Returns the broker only if it implements
  /// [T]; otherwise null.
  ///
  /// ```dart
  /// final embedBroker = AiBrokerRegistry.instance.lookupAs<EmbedBroker>('anthropic');
  /// // → null (Anthropic doesn't implement EmbedBroker)
  /// ```
  T? lookupAs<T extends AiBroker>(String id) {
    final b = _brokers[id];
    return b is T ? b : null;
  }

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
