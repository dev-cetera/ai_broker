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

/// What [KeyCheckBroker.checkKey] found out about an API key.
enum AiKeyStatus {
  /// The provider accepted the key.
  valid,

  /// The provider rejected the key (HTTP 401 / 403, or Gemini's
  /// `API_KEY_INVALID`), or the key was empty.
  invalid,

  /// The provider could not be reached: no network, a timeout, a 5xx, or
  /// (on the web) a request the browser blocked. Says nothing about the key.
  unreachable,

  /// The provider answered with another error, such as 402 (no credit) or
  /// 429 (rate limited). The key is probably real; [AiKeyCheck.message]
  /// says what went wrong.
  error,
}

/// The result of [KeyCheckBroker.checkKey]: a status a settings screen can
/// branch on, plus the HTTP status and the provider's message when there was
/// one.
@immutable
class AiKeyCheck {
  final AiKeyStatus status;

  /// The HTTP status the provider answered with, or `null` when no response
  /// arrived.
  final int? statusCode;

  /// The provider's error text, or a description of the network failure.
  /// `null` when the key is valid.
  final String? message;

  const AiKeyCheck(this.status, {this.statusCode, this.message});

  bool get isValid => status == AiKeyStatus.valid;

  @override
  bool operator ==(Object other) =>
      other is AiKeyCheck &&
      other.status == status &&
      other.statusCode == statusCode &&
      other.message == message;

  @override
  int get hashCode => Object.hash(status, statusCode, message);

  @override
  String toString() => 'AiKeyCheck(${status.name}'
      '${statusCode == null ? '' : ', HTTP $statusCode'}'
      '${message == null ? '' : ', $message'})';
}

/// Key-check capability: tells a valid key from a rejected one and from a
/// provider that could not be reached, which [AiBroker.listModels] cannot
/// (it returns `[]` for all three). Every built-in broker implements it;
/// look it up with `AiBrokerRegistry.instance.lookupAs<KeyCheckBroker>(id)`.
///
/// A check costs no tokens: it is a metadata request (usually the model
/// list), never a completion.
abstract class KeyCheckBroker implements AiBroker {
  Future<AiKeyCheck> checkKey(String apiKey);
}

/// Shared implementation of [KeyCheckBroker.checkKey]: sends [send] once (no
/// retries; a settings screen wants an answer now) and classifies the
/// outcome. [isInvalidKey] lets a provider that reports a bad key with
/// another status (Gemini answers 400 `API_KEY_INVALID`) say so.
Future<AiKeyCheck> checkKeyByRequest(
  String apiKey, {
  required String providerLabel,
  required Future<Response> Function() send,
  bool Function(Response response)? isInvalidKey,
}) async {
  if (apiKey.trim().isEmpty) {
    return const AiKeyCheck(AiKeyStatus.invalid, message: 'No key entered.');
  }
  final Response res;
  try {
    res = await send();
  } on TimeoutException {
    return AiKeyCheck(
      AiKeyStatus.unreachable,
      message: '$providerLabel did not answer in time.',
    );
  } on ClientException catch (e) {
    return AiKeyCheck(AiKeyStatus.unreachable, message: e.message);
  }
  final code = res.statusCode;
  if (code >= 200 && code < 300) return const AiKeyCheck(AiKeyStatus.valid);
  final message = _errorMessage(res.body);
  if (code == 401 || code == 403 || (isInvalidKey?.call(res) ?? false)) {
    return AiKeyCheck(AiKeyStatus.invalid, statusCode: code, message: message);
  }
  if (code >= 500) {
    return AiKeyCheck(
      AiKeyStatus.unreachable,
      statusCode: code,
      message: message,
    );
  }
  return AiKeyCheck(AiKeyStatus.error, statusCode: code, message: message);
}

/// True when a Google API (Gemini, Cloud Translation) says the key itself is
/// bad: those APIs answer 400 with reason `API_KEY_INVALID` rather than 401.
bool isGoogleInvalidKey(Response response) =>
    response.statusCode == 400 && response.body.contains('API_KEY_INVALID');

/// Pulls `error.message` (or a string `error`) out of a JSON error body,
/// falling back to the raw body.
String? _errorMessage(String body) {
  if (body.isEmpty) return null;
  try {
    final json = jsonDecode(body);
    if (json is Map<String, Object?>) {
      final error = json['error'];
      if (error is Map<String, Object?> && error['message'] is String) {
        return error['message'] as String;
      }
      if (error is String) return error;
    }
  } on FormatException {
    // Not JSON: fall through to the raw body.
  }
  return body.length > 300 ? '${body.substring(0, 300)}…' : body;
}
