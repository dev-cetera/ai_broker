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

import 'dart:convert';

import 'package:ai_broker/ai_broker.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:test/test.dart';

void main() {
  group('GoogleTranslateBroker', () {
    test('id and label', () {
      final b = GoogleTranslateBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      expect(b.id, 'google_translate');
      expect(b.label, contains('Google'));
    });

    test('listModels always returns empty (v2 has no listable models)',
        () async {
      final b = GoogleTranslateBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      expect(await b.listModels('k'), isEmpty);
    });

    test('implements TranslateBroker, not ChatBroker or EmbedBroker', () {
      final b = GoogleTranslateBroker(
        client: MockClient((_) async => Response('', 200)),
      );
      expect(b, isA<TranslateBroker>());
      expect(b, isNot(isA<ChatBroker>()));
      expect(b, isNot(isA<EmbedBroker>()));
    });

    group('translate', () {
      test('posts the documented v2 payload and returns the translation',
          () async {
        late Uri sentUri;
        late Map<String, Object?> sentBody;
        final b = GoogleTranslateBroker(
          client: MockClient((req) async {
            expect(req.method, 'POST');
            sentUri = req.url;
            expect(req.headers['Content-Type'], 'application/json');
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'data': {
                  'translations': [
                    {
                      'translatedText': 'bonjour',
                      'detectedSourceLanguage': 'en',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );
        final result = await b.translate(
          apiKey: 'AIza-test',
          text: 'hello',
          to: 'fr',
        );
        expect(
          sentUri.toString(),
          'https://translation.googleapis.com/language/translate/v2'
          '?key=AIza-test',
        );
        expect(sentBody['q'], 'hello');
        expect(sentBody['target'], 'fr');
        expect(sentBody['format'], 'text'); // no glossary → text mode
        expect(sentBody.containsKey('source'), isFalse);
        expect(result.translated, 'bonjour');
        expect(result.detectedFrom, 'en');
      });

      test('passes --from through as the source language', () async {
        Map<String, Object?>? sentBody;
        final b = GoogleTranslateBroker(
          client: MockClient((req) async {
            sentBody = jsonDecode(req.body) as Map<String, Object?>;
            return Response(
              jsonEncode({
                'data': {
                  'translations': [
                    {'translatedText': 'x'},
                  ],
                },
              }),
              200,
            );
          }),
        );
        await b.translate(
          apiKey: 'k',
          text: 'hello',
          to: 'fr',
          from: 'en',
        );
        expect(sentBody!['source'], 'en');
      });

      test(
          'wraps glossary terms in <span translate="no"> and strips them '
          'from the response', () async {
        String? sentText;
        final b = GoogleTranslateBroker(
          client: MockClient((req) async {
            final body = jsonDecode(req.body) as Map<String, Object?>;
            sentText = body['q'] as String;
            expect(body['format'], 'html');
            // Pretend Google echoed the spans back unchanged (it's
            // supposed to, but the broker should strip them anyway).
            final wrapped =
                '<span translate="no">BME280</span> est un capteur.';
            return Response(
              jsonEncode({
                'data': {
                  'translations': [
                    {'translatedText': wrapped},
                  ],
                },
              }),
              200,
            );
          }),
        );
        final result = await b.translate(
          apiKey: 'k',
          text: 'BME280 is a sensor.',
          to: 'fr',
          glossary: const {'BME280': 'BME280'},
        );
        // Sent payload: glossary key replaced by the wrapped marker.
        expect(
          sentText,
          contains('<span translate="no">BME280</span>'),
        );
        // Response: spans stripped, inner text retained.
        expect(result.translated, 'BME280 est un capteur.');
        expect(result.translated, isNot(contains('<span')));
      });

      test(
          'glossary path escapes input HTML and decodes entities in the '
          'response', () async {
        String? sentText;
        final b = GoogleTranslateBroker(
          client: MockClient((req) async {
            final body = jsonDecode(req.body) as Map<String, Object?>;
            sentText = body['q'] as String;
            expect(body['format'], 'html');
            // Google echoes back a glossary span plus HTML-encoded
            // entities for `<`, `&`, `"` that appeared in the source.
            return Response(
              jsonEncode({
                'data': {
                  'translations': [
                    {
                      'translatedText':
                          '<span translate="no">BME280</span> is &quot;'
                              'A &amp; B&quot; &lt;tag&gt;',
                    },
                  ],
                },
              }),
              200,
            );
          }),
        );
        final result = await b.translate(
          apiKey: 'k',
          text: 'BME280 is "A & B" <tag>',
          to: 'fr',
          glossary: const {'BME280': 'BME280'},
        );
        // Sent payload: source's special chars are HTML-escaped so they
        // round-trip through the `format: 'html'` request.
        expect(sentText, contains('&quot;A &amp; B&quot; &lt;tag&gt;'));
        expect(sentText, contains('<span translate="no">BME280</span>'));
        // Response: spans stripped, entities decoded back to plain text.
        expect(result.translated, 'BME280 is "A & B" <tag>');
      });

      test('escapes HTML special chars in glossary targets', () async {
        String? sentText;
        final b = GoogleTranslateBroker(
          client: MockClient((req) async {
            final body = jsonDecode(req.body) as Map<String, Object?>;
            sentText = body['q'] as String;
            return Response(
              jsonEncode({
                'data': {
                  'translations': [
                    {'translatedText': 'x'},
                  ],
                },
              }),
              200,
            );
          }),
        );
        await b.translate(
          apiKey: 'k',
          text: 'foo',
          to: 'fr',
          glossary: const {'foo': 'A<B&C'},
        );
        // Target must not introduce unbalanced markup.
        expect(sentText, contains('<span translate="no">A&lt;B&amp;C</span>'));
      });

      test('preserves a literal `&lt;` in the source through round-trip',
          () async {
        // The old multi-pass decoder mangled this: it first turned
        // `&lt;` → `<`, then `&amp;` → `&`, so a user-typed `&lt;`
        // (escaped on the wire to `&amp;lt;` then echoed back unchanged)
        // landed as `&<` instead of `&lt;`. Single-pass decoding keeps
        // it intact.
        final b = GoogleTranslateBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'data': {
                  'translations': [
                    {
                      'translatedText':
                          '<span translate="no">X</span> &amp;lt;',
                    },
                  ],
                },
              }),
              200,
            ),
          ),
        );
        final result = await b.translate(
          apiKey: 'k',
          text: 'X &lt;',
          to: 'fr',
          glossary: const {'X': 'X'},
        );
        expect(result.translated, 'X &lt;');
      });

      test('throws AiBrokerException on a 4xx response', () async {
        final b = GoogleTranslateBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'error': {'message': 'API key not valid.'},
              }),
              400,
            ),
          ),
        );
        await expectLater(
          b.translate(apiKey: 'bad', text: 'x', to: 'fr'),
          throwsA(isA<AiBrokerException>()),
        );
      });

      test('throws when response has no translations', () async {
        final b = GoogleTranslateBroker(
          client: MockClient(
            (_) async => Response(
              jsonEncode({
                'data': {'translations': <Object?>[]},
              }),
              200,
            ),
          ),
        );
        await expectLater(
          b.translate(apiKey: 'k', text: 'x', to: 'fr'),
          throwsA(isA<AiBrokerException>()),
        );
      });
    });
  });
}
