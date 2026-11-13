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

import 'dart:async';

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('checkKeyByRequest', () {
    Future<AiKeyCheck> check(
      Response response, {
      bool Function(Response)? isInvalidKey,
    }) =>
        checkKeyByRequest(
          'k',
          providerLabel: 'P',
          send: () async => response,
          isInvalidKey: isInvalidKey,
        );

    test('2xx is valid', () async {
      expect(
        await check(Response('{}', 200)),
        const AiKeyCheck(AiKeyStatus.valid),
      );
    });

    test('401 and 403 are invalid', () async {
      expect((await check(Response('', 401))).status, AiKeyStatus.invalid);
      expect((await check(Response('', 403))).status, AiKeyStatus.invalid);
    });

    test('a provider-specific invalid-key answer is invalid', () async {
      final res = Response(
        '{"error":{"message":"API key not valid.","status":"INVALID_ARGUMENT",'
        '"details":[{"reason":"API_KEY_INVALID"}]}}',
        400,
      );
      final out = await check(res, isInvalidKey: isGoogleInvalidKey);
      expect(out.status, AiKeyStatus.invalid);
      expect(out.message, 'API key not valid.');
    });

    test('another 400 is an error', () async {
      final out = await check(Response('{"error":"bad request"}', 400));
      expect(out.status, AiKeyStatus.error);
      expect(out.message, 'bad request');
    });

    test('a timeout is unreachable', () async {
      final out = await checkKeyByRequest(
        'k',
        providerLabel: 'P',
        send: () async => throw TimeoutException('slow'),
      );
      expect(out.status, AiKeyStatus.unreachable);
      expect(out.message, contains('P'));
    });

    test('a long non-JSON body is shortened', () async {
      final out = await check(Response('x' * 1000, 418));
      expect(out.message!.length, lessThan(320));
    });
  });

  group('built-in brokers', () {
    test('every built-in broker can check a key', () {
      final client = MockClient((_) async => Response('{}', 200));
      expect(OpenAiBroker(client: client), isA<KeyCheckBroker>());
      expect(DeepSeekBroker(client: client), isA<KeyCheckBroker>());
      expect(AnthropicBroker(client: client), isA<KeyCheckBroker>());
      expect(GeminiBroker(client: client), isA<KeyCheckBroker>());
      expect(GoogleTranslateBroker(client: client), isA<KeyCheckBroker>());
    });

    test('Anthropic checks /models with its own headers', () async {
      late Request sent;
      final b = AnthropicBroker(
        client: MockClient((req) async {
          sent = req;
          return Response('{"data":[]}', 200);
        }),
      );
      expect((await b.checkKey('sk-ant')).isValid, isTrue);
      expect(sent.url.toString(), 'https://api.anthropic.com/v1/models');
      expect(sent.headers['x-api-key'], 'sk-ant');
      expect(sent.headers['anthropic-version'], isNotNull);
    });

    test('Gemini reads 400 API_KEY_INVALID as an invalid key', () async {
      final b = GeminiBroker(
        client: MockClient(
          (_) async => Response(
            '{"error":{"code":400,"message":"API key not valid. Please pass a '
            'valid API key.","details":[{"reason":"API_KEY_INVALID"}]}}',
            400,
          ),
        ),
      );
      expect((await b.checkKey('AIza-bad')).status, AiKeyStatus.invalid);
    });

    test('Google Translate checks the free languages call', () async {
      late Request sent;
      final b = GoogleTranslateBroker(
        client: MockClient((req) async {
          sent = req;
          return Response('{"data":{"languages":[]}}', 200);
        }),
      );
      expect((await b.checkKey('AIza')).isValid, isTrue);
      expect(sent.url.path, '/language/translate/v2/languages');
      expect(sent.url.queryParameters['key'], 'AIza');
    });
  });
}
