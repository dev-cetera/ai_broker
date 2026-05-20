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

/// Where API keys come from. Flutter apps with secure storage implement
/// this against their own store; CLI / backend code can use the
/// built-in [EnvKeyResolver] or [MapKeyResolver].
///
/// [brokerId] is the same id as [AiBroker.id] — `'openai'`,
/// `'anthropic'`, `'gemini'`.
abstract class KeyResolver {
  Future<String?> resolve(String brokerId);

  /// Same as [resolve] but throws [MissingKeyException] when the key is
  /// missing or empty. Useful at the call site of `broker.complete(...)`
  /// where empty-string would just yield an opaque HTTP 401.
  Future<String> require(String brokerId) async {
    final key = await resolve(brokerId);
    if (key == null || key.isEmpty) {
      throw MissingKeyException(brokerId);
    }
    return key;
  }
}

/// Reads keys from `Platform.environment` using a per-broker env var
/// name. Defaults follow the SDK conventions each provider documents:
///
///  - `openai`    → `OPENAI_API_KEY`
///  - `anthropic` → `ANTHROPIC_API_KEY`
///  - `gemini`    → `GEMINI_API_KEY`
///
/// Override individual mappings via the constructor when an
/// environment uses a different name (e.g. `GOOGLE_API_KEY`).
class EnvKeyResolver extends KeyResolver {
  final Map<String, String> envVarNames;

  EnvKeyResolver({Map<String, String>? overrides})
      : envVarNames = {
          'openai': 'OPENAI_API_KEY',
          'anthropic': 'ANTHROPIC_API_KEY',
          'gemini': 'GEMINI_API_KEY',
          ...?overrides,
        };

  @override
  Future<String?> resolve(String brokerId) async {
    final name = envVarNames[brokerId];
    if (name == null) return null;
    final value = Platform.environment[name];
    if (value == null || value.isEmpty) return null;
    return value;
  }
}

/// In-memory resolver — for tests, or for apps that already hold keys
/// in a runtime-built map.
class MapKeyResolver extends KeyResolver {
  final Map<String, String> keys;
  MapKeyResolver(this.keys);

  @override
  Future<String?> resolve(String brokerId) async => keys[brokerId];
}

class MissingKeyException implements Exception {
  final String brokerId;
  const MissingKeyException(this.brokerId);
  @override
  String toString() =>
      'MissingKeyException: no API key configured for broker "$brokerId".';
}
