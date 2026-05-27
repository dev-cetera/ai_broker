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

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:test/test.dart';

Response _ok() => Response('{"ok":true}', 200);

void main() {
  group('retryRequest', () {
    test('returns immediately on a 2xx response', () async {
      var calls = 0;
      final res = await retryRequest(
        send: () async {
          calls++;
          return _ok();
        },
        providerLabel: 'Test',
        baseDelay: Duration.zero,
      );
      expect(res.statusCode, 200);
      expect(calls, 1);
    });

    test('retries on 429 then succeeds', () async {
      final statuses = [429, 429, 200];
      var i = 0;
      final res = await retryRequest(
        send: () async => Response('body', statuses[i++]),
        providerLabel: 'Test',
        baseDelay: Duration.zero,
      );
      expect(res.statusCode, 200);
      expect(i, 3);
    });

    test('retries on 503 then succeeds', () async {
      final statuses = [503, 200];
      var i = 0;
      final res = await retryRequest(
        send: () async => Response('body', statuses[i++]),
        providerLabel: 'Test',
        baseDelay: Duration.zero,
      );
      expect(res.statusCode, 200);
      expect(i, 2);
    });

    test('retries on 529 (Anthropic overload) then succeeds', () async {
      final statuses = [529, 200];
      var i = 0;
      final res = await retryRequest(
        send: () async => Response('body', statuses[i++]),
        providerLabel: 'Test',
        baseDelay: Duration.zero,
      );
      expect(res.statusCode, 200);
      expect(i, 2);
    });

    test('throws AiBrokerException for non-retryable 4xx', () async {
      await expectLater(
        retryRequest(
          send: () async => Response('{"error":{"message":"bad"}}', 400),
          providerLabel: 'OpenAI',
          baseDelay: Duration.zero,
        ),
        throwsA(
          isA<AiBrokerException>()
              .having((e) => e.statusCode, 'statusCode', 400)
              .having((e) => e.message, 'message', contains('OpenAI 400'))
              .having((e) => e.message, 'message', contains('bad')),
        ),
      );
    });

    test('falls back to the raw body when error.message is missing', () async {
      await expectLater(
        retryRequest(
          send: () async => Response('plain text body', 500),
          providerLabel: 'OpenAI',
          baseDelay: Duration.zero,
        ),
        throwsA(
          isA<AiBrokerException>()
              .having((e) => e.message, 'message', contains('plain text body')),
        ),
      );
    });

    test('hard-failure predicate short-circuits a 429', () async {
      var calls = 0;
      await expectLater(
        retryRequest(
          send: () async {
            calls++;
            return Response(
              '{"error":{"message":"quota exceeded"}}',
              429,
            );
          },
          providerLabel: 'OpenAI',
          baseDelay: Duration.zero,
          isHardFailure: (r) => r.body.contains('quota'),
        ),
        throwsA(
          isA<AiBrokerException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having(
                (e) => e.message,
                'message',
                contains('quota exceeded'),
              ),
        ),
      );
      expect(calls, 1, reason: 'hard failure should not retry');
    });

    test('throws after exhausting maxAttempts on persistent 429', () async {
      var calls = 0;
      await expectLater(
        retryRequest(
          send: () async {
            calls++;
            return Response('busy', 429);
          },
          providerLabel: 'Test',
          maxAttempts: 3,
          baseDelay: Duration.zero,
        ),
        throwsA(
          isA<AiBrokerException>()
              .having((e) => e.statusCode, 'statusCode', 429)
              .having(
                (e) => e.message,
                'message',
                contains('still rate-limited after 3 attempts'),
              ),
        ),
      );
      expect(calls, 3);
    });

    test('AiBrokerException.toString includes status code when set', () {
      const e = AiBrokerException('bad', statusCode: 418);
      expect(e.toString(), 'HTTP 418: bad');
    });

    test('AiBrokerException.toString omits prefix when status code is null',
        () {
      const e = AiBrokerException('plain');
      expect(e.toString(), 'plain');
    });
  });
}
