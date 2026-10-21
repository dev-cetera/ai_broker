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
/// fine": rate limits (429), transient server errors (500, 502, 504) and
/// upstream overload (503, Anthropic's 529). Quota-exceeded (a hard 429
/// with `quota` in the body) is *not* retryable — callers pass
/// `isHardFailure` to surface that to the user instead of burning attempts.
const retryableStatusCodes = {429, 500, 502, 503, 504, 529};

/// HTTP retry with exponential backoff: up to [maxAttempts] tries, waiting
/// [baseDelay] × 2ⁿ between them. Shared by every broker so retry policy
/// lives in one place.
///
/// [send] runs the request. It is retried when:
///  - the response status is in [retryableStatusCodes]. When the response
///    carries a `Retry-After` header (seconds or an HTTP-date), that wait
///    replaces the backoff, capped at [maxRetryAfter];
///  - [send] throws a transient network error: a `ClientException` from
///    `package:http` (which also covers socket failures — `IOClient`
///    rethrows a `SocketException` as one).
///
/// A `TimeoutException` is deliberately NOT retried: the provider may still
/// be generating (and billing) the timed-out request, so re-sending a long
/// generation would multiply its cost. It propagates untouched.
///
/// Any other ≥400 throws [AiBrokerException] with the body; any other
/// exception from [send] propagates untouched. After [maxAttempts], throws
/// [AiBrokerException].
///
/// [providerLabel] is used in error messages so the user can tell
/// which provider failed (`'OpenAI 429: ...'`).
///
/// [wait] performs the pause between attempts; tests pass a recorder.
Future<Response> retryRequest({
  required Future<Response> Function() send,
  required String providerLabel,
  int maxAttempts = 5,
  Duration baseDelay = const Duration(seconds: 5),
  Duration maxRetryAfter = const Duration(seconds: 60),
  bool Function(Response)? isHardFailure,
  Future<void> Function(Duration) wait = _sleep,
}) async {
  for (var attempt = 0; attempt < maxAttempts; attempt++) {
    final isLastAttempt = attempt == maxAttempts - 1;
    final backoff = baseDelay * (1 << attempt);
    final Response res;
    try {
      res = await send();
    } on ClientException catch (e) {
      if (isLastAttempt) throw _networkFailure(providerLabel, maxAttempts, e);
      await wait(backoff);
      continue;
    }
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
      if (isLastAttempt) {
        throw AiBrokerException(
          '$providerLabel still failing (HTTP ${res.statusCode}) after '
          '$maxAttempts attempts: ${_safeBody(res)}',
          statusCode: res.statusCode,
        );
      }
      final retryAfter = _retryAfter(res);
      await wait(
        retryAfter == null
            ? backoff
            : (retryAfter > maxRetryAfter ? maxRetryAfter : retryAfter),
      );
      continue;
    }
    throw AiBrokerException(
      '$providerLabel ${res.statusCode}: ${_safeBody(res)}',
      statusCode: res.statusCode,
    );
  }
  // Unreachable — the loop either returns, throws, or hits the
  // last-attempt guards above.
  throw AiBrokerException(
    '$providerLabel: retry loop exhausted',
  );
}

Future<void> _sleep(Duration duration) => Future<void>.delayed(duration);

AiBrokerException _networkFailure(
  String providerLabel,
  int maxAttempts,
  Object error,
) =>
    AiBrokerException(
      '$providerLabel request failed after $maxAttempts attempts: $error',
    );

/// The wait a `Retry-After` header asks for: whole seconds or an HTTP-date.
/// `null` when the header is absent or unreadable (the caller then falls
/// back to its backoff). A date already in the past means "now".
Duration? _retryAfter(Response res) {
  final value = res.headers['retry-after']?.trim();
  if (value == null || value.isEmpty) return null;
  final seconds = int.tryParse(value);
  if (seconds != null) {
    return seconds < 0 ? null : Duration(seconds: seconds);
  }
  final DateTime date;
  try {
    date = HttpDate.parse(value);
  } on HttpException {
    return null;
  }
  final untilThen = date.difference(DateTime.now().toUtc());
  return untilThen.isNegative ? Duration.zero : untilThen;
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
