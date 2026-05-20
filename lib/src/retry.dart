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

/// Status codes that mean "try again later, the request itself is
/// fine": rate limits and transient upstream overload. Quota-exceeded
/// (a hard 429 with `quota` in the body) is *not* retryable — callers
/// should surface that to the user instead of burning attempts.
const retryableStatusCodes = {429, 503, 529};

/// HTTP retry with exponential backoff capped at 5 attempts × 5s × 2ⁿ.
/// Matches the loop used in chitbot's `OpenAiBot` / `GeminiBot` /
/// `ClaudeClient`, generalised so all three brokers share one path.
///
/// [send] runs the request. On a status in [retryableStatusCodes],
/// waits and retries. On any other ≥400, throws [AiBrokerException]
/// with the body. After [maxAttempts], throws.
///
/// [providerLabel] is used in error messages so the user can tell
/// which provider failed (`'OpenAI 429: ...'`).
Future<Response> retryRequest({
  required Future<Response> Function() send,
  required String providerLabel,
  int maxAttempts = 5,
  Duration baseDelay = const Duration(seconds: 5),
  bool Function(Response)? isHardFailure,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final res = await send();
    if (res.statusCode >= 200 && res.statusCode < 300) return res;
    if (retryableStatusCodes.contains(res.statusCode)) {
      // Surface hard failures (e.g. quota exceeded) immediately rather
      // than wasting four more attempts on something that won't recover.
      if (isHardFailure != null && isHardFailure(res)) {
        throw AiBrokerException(
          '$providerLabel ${res.statusCode}: ${_safeBody(res)}',
          statusCode: res.statusCode,
        );
      }
      if (attempt == maxAttempts - 1) {
        throw AiBrokerException(
          '$providerLabel still rate-limited after $maxAttempts attempts',
          statusCode: res.statusCode,
        );
      }
      await Future<void>.delayed(baseDelay * (1 << attempt));
      continue;
    }
    throw AiBrokerException(
      '$providerLabel ${res.statusCode}: ${_safeBody(res)}',
      statusCode: res.statusCode,
    );
  }
  // Unreachable — the loop either returns, throws, or hits the
  // maxAttempts guard above.
  throw AiBrokerException(
    '$providerLabel: retry loop exhausted',
  );
}

/// Pulls an `error.message` string out of a provider's JSON error
/// envelope when present; otherwise returns the raw body. All three
/// brokers use the same `{error: {message}}` shape.
String _safeBody(Response res) {
  try {
    final json = jsonDecode(res.body);
    if (json is Map<String, Object?>) {
      final err = json['error'];
      if (err is Map<String, Object?>) {
        final msg = err['message'];
        if (msg is String) return msg;
      }
    }
  } catch (_) {}
  return res.body;
}
