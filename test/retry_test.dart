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
import 'dart:io' show HttpDate;

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

    for (final status in [500, 502, 504]) {
      test('retries on $status then succeeds', () async {
        final statuses = [status, 200];
        var i = 0;
        final res = await retryRequest(
          send: () async => Response('body', statuses[i++]),
          providerLabel: 'Test',
          baseDelay: Duration.zero,
        );
        expect(res.statusCode, 200);
        expect(i, 2);
      });
    }

    test('retries a ClientException (network failure) then succeeds', () async {
      var calls = 0;
      final res = await retryRequest(
        send: () async {
          calls++;
          if (calls == 1) throw ClientException('Connection reset');
          return _ok();
        },
        providerLabel: 'Test',
        baseDelay: Duration.zero,
      );
      expect(res.statusCode, 200);
      expect(calls, 2);
    });

    test('does not retry a TimeoutException (the provider may still bill it)',
        () async {
      var calls = 0;
      await expectLater(
        retryRequest(
          send: () async {
            calls++;
            throw TimeoutException('slow');
          },
          providerLabel: 'Test',
          baseDelay: Duration.zero,
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(calls, 1);
    });

    test('wraps a network failure that outlasts every attempt', () async {
      var calls = 0;
      await expectLater(
        retryRequest(
          send: () async {
            calls++;
            throw ClientException('Failed host lookup');
          },
          providerLabel: 'Test',
          maxAttempts: 3,
          baseDelay: Duration.zero,
        ),
        throwsA(
          isA<AiBrokerException>()
              .having((e) => e.statusCode, 'statusCode', isNull)
              .having(
                (e) => e.message,
                'message',
                allOf(
                  contains('Test request failed after 3 attempts'),
                  contains('Failed host lookup'),
                ),
              ),
        ),
      );
      expect(calls, 3);
    });

    test('does not retry other exceptions', () async {
      var calls = 0;
      await expectLater(
        retryRequest(
          send: () async {
            calls++;
            throw StateError('bug');
          },
          providerLabel: 'Test',
          baseDelay: Duration.zero,
        ),
        throwsStateError,
      );
      expect(calls, 1);
    });

    group('Retry-After', () {
      Future<List<Duration>> waitsFor(
        Response first, {
        Duration baseDelay = const Duration(seconds: 5),
        Duration maxRetryAfter = const Duration(seconds: 60),
      }) async {
        final waits = <Duration>[];
        final responses = [first, _ok()];
        var i = 0;
        await retryRequest(
          send: () async => responses[i++],
          providerLabel: 'Test',
          baseDelay: baseDelay,
          maxRetryAfter: maxRetryAfter,
          wait: (d) async => waits.add(d),
        );
        return waits;
      }

      test('without the header, waits the exponential backoff', () async {
        final waits = await waitsFor(Response('busy', 503));
        expect(waits, [const Duration(seconds: 5)]);
      });

      test('honours a delay in seconds', () async {
        final waits = await waitsFor(
          Response('busy', 429, headers: {'retry-after': '2'}),
        );
        expect(waits, [const Duration(seconds: 2)]);
      });

      test('caps a long delay at maxRetryAfter', () async {
        final waits = await waitsFor(
          Response('busy', 503, headers: {'retry-after': '3600'}),
          maxRetryAfter: const Duration(seconds: 30),
        );
        expect(waits, [const Duration(seconds: 30)]);
      });

      test('honours an HTTP-date, capped at maxRetryAfter', () async {
        final later = DateTime.now().toUtc().add(const Duration(hours: 1));
        final waits = await waitsFor(
          Response(
            'busy',
            503,
            headers: {'retry-after': HttpDate.format(later)},
          ),
          maxRetryAfter: const Duration(seconds: 45),
        );
        expect(waits, [const Duration(seconds: 45)]);
      });

      test('an HTTP-date in the past means retry now', () async {
        final earlier =
            DateTime.now().toUtc().subtract(const Duration(hours: 1));
        final waits = await waitsFor(
          Response(
            'busy',
            503,
            headers: {'retry-after': HttpDate.format(earlier)},
          ),
        );
        expect(waits, [Duration.zero]);
      });

      test('an unreadable value falls back to the backoff', () async {
        final waits = await waitsFor(
          Response('busy', 503, headers: {'retry-after': 'soon'}),
          baseDelay: const Duration(seconds: 3),
        );
        expect(waits, [const Duration(seconds: 3)]);
      });
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
          send: () async => Response('plain text body', 404),
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
                contains('Test still failing (HTTP 429) after 3 attempts'),
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
