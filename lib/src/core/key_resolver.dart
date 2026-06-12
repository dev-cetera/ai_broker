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

import 'dart:io';

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
          'google_translate': 'GOOGLE_TRANSLATE_API_KEY',
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

/// Reads keys from a plain-text file. The format is intentionally loose
/// so users can keep notes alongside their keys:
///
/// ```
/// # Comments and blank lines are ignored.
/// anthropic: sk-ant-...
/// claude: sk-ant-...          # alias for 'anthropic'
/// openai key: sk-...          # alias for 'openai'
/// gemini: AIza...
/// OPENAI_API_KEY=sk-...       # env-var style also works
/// ```
///
/// Recognised broker labels (case-insensitive, all stripped of `_api_key`,
/// `api_key`, ` key`):
///
/// | Aliases                     | Resolves to |
/// |-----------------------------|-------------|
/// | `openai`                    | `openai`    |
/// | `anthropic`, `claude`       | `anthropic` |
/// | `gemini`, `google`          | `gemini`    |
///
/// Unrecognised lines are silently skipped (so e.g. `notes: rotate Friday`
/// doesn't break parsing).
///
/// **The file is read only when a resolver is constructed via
/// [FileKeyResolver.fromFile]; keys never leave the CLI process.**
/// Importantly for slash-command workflows: Claude doesn't see the file
/// contents — only the `--keys-file <path>` flag passed to the CLI.
class FileKeyResolver extends KeyResolver {
  final Map<String, String> _keys;

  FileKeyResolver(this._keys);

  factory FileKeyResolver.fromFile(String path) {
    final file = File(path);
    if (!file.existsSync()) {
      throw FormatException(
        'FileKeyResolver: key file not found at $path',
      );
    }
    final lines = file.readAsLinesSync();
    final keys = <String, String>{};
    for (final raw in lines) {
      final line = raw.trim();
      if (line.isEmpty || line.startsWith('#') || line.startsWith('//')) {
        continue;
      }
      // Prefer `=` (env-var style) when both `=` and `:` are present.
      String left, right;
      final eqIdx = line.indexOf('=');
      final colIdx = line.indexOf(':');
      if (eqIdx > 0 && (colIdx < 0 || eqIdx < colIdx)) {
        left = line.substring(0, eqIdx).trim();
        right = line.substring(eqIdx + 1).trim();
      } else if (colIdx > 0) {
        left = line.substring(0, colIdx).trim();
        right = line.substring(colIdx + 1).trim();
      } else {
        continue;
      }
      if (right.isEmpty) continue;

      final id = _normalizeLabel(left);
      if (id != null) keys[id] = right;
    }
    return FileKeyResolver(keys);
  }

  static String? _normalizeLabel(String raw) {
    final lower = raw.toLowerCase().trim();
    final cleaned = lower
        .replaceAll('_api_key', '')
        .replaceAll('-api-key', '')
        .replaceAll(' api key', '')
        .replaceAll(' key', '')
        .trim();
    switch (cleaned) {
      case 'openai':
        return 'openai';
      case 'anthropic':
      case 'claude':
        return 'anthropic';
      case 'gemini':
        return 'gemini';
      case 'google_translate':
      case 'google translate':
      case 'googletranslate':
        return 'google_translate';
      default:
        return null;
    }
  }

  @override
  Future<String?> resolve(String brokerId) async => _keys[brokerId];

  /// Broker ids that were resolved successfully — useful for diagnostics.
  Iterable<String> get resolvedIds => _keys.keys;
}

/// Tries each underlying resolver in order, returns the first non-empty
/// hit. Used by the CLI to layer direct flags → `.env` file → env vars.
class ChainedKeyResolver extends KeyResolver {
  final List<KeyResolver> resolvers;
  ChainedKeyResolver(this.resolvers);

  @override
  Future<String?> resolve(String brokerId) async {
    for (final r in resolvers) {
      final key = await r.resolve(brokerId);
      if (key != null && key.isNotEmpty) return key;
    }
    return null;
  }
}

class MissingKeyException implements Exception {
  final String brokerId;
  const MissingKeyException(this.brokerId);
  @override
  String toString() =>
      'MissingKeyException: no API key configured for broker "$brokerId".';
}
