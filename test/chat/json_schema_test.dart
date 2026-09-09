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
import 'package:test/test.dart';

import '../support/judge_schema.dart';

void main() {
  group('toGeminiSchema', () {
    test('drops additionalProperties everywhere, not just at the root', () {
      final out = toGeminiSchema(kJudgeJsonSchema)!;
      expect(
        allKeysDeep(kJudgeJsonSchema),
        contains('additionalProperties'),
        reason: 'the fixture must actually contain the keyword to be a test',
      );
      expect(
        allKeysDeep(out),
        isNot(contains('additionalProperties')),
        reason: 'Gemini 400s: Unknown name "additionalProperties" at '
            "'generation_config.response_schema'",
      );
    });

    test('rewrites nullable unions as type + nullable', () {
      final out = toGeminiSchema(kJudgeJsonSchema)!;
      final properties = out['properties']! as Map<String, Object?>;

      final prompt = properties['improved_prompt']! as Map<String, Object?>;
      expect(prompt['type'], 'string');
      expect(prompt['nullable'], isTrue);

      final questions =
          properties['improved_questions']! as Map<String, Object?>;
      expect(questions['type'], 'array');
      expect(questions['nullable'], isTrue);
      // The union rewrite must not cost the array its element schema.
      expect(questions['items'], isA<Map<String, Object?>>());
    });

    test('leaves a non-nullable field without a nullable flag', () {
      final out = toGeminiSchema(kJudgeJsonSchema)!;
      final properties = out['properties']! as Map<String, Object?>;
      final changelog = properties['changelog']! as Map<String, Object?>;
      expect(changelog.containsKey('nullable'), isFalse);
      expect(out.containsKey('nullable'), isFalse);
    });

    test('translates the judge schema whole', () {
      expect(toGeminiSchema(kJudgeJsonSchema), {
        'type': 'object',
        'required': [
          'scores',
          'improved_questions',
          'improved_prompt',
          'changelog',
        ],
        'properties': {
          'scores': {
            'type': 'array',
            'items': {
              'type': 'object',
              'required': ['index', 'verdict', 'reason'],
              'properties': {
                'index': {
                  'type': 'integer',
                  'description': '1-based index of the question being scored.',
                },
                'verdict': {
                  'type': 'string',
                  'enum': ['PASS', 'FAIL', 'SKIP'],
                },
                'reason': {
                  'type': 'string',
                  'description': 'One short sentence justifying the verdict.',
                },
              },
            },
          },
          'improved_questions': {
            'type': 'array',
            'nullable': true,
            'items': {
              'type': 'object',
              'required': ['q', 'expected'],
              'properties': {
                'q': {'type': 'string'},
                'expected': {'type': 'string'},
              },
            },
          },
          'improved_prompt': {
            'type': 'string',
            'nullable': true,
            'description':
                'The full rewritten system prompt, or null to decline.',
          },
          'changelog': {
            'type': 'string',
            'description': 'Short bullet list of what changed and why.',
          },
        },
      });
    });

    test('drops the meta keywords Gemini has no field for', () {
      const schema = {
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        r'$id': 'https://example.com/judge.json',
        'title': 'Judge',
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
        r'$defs': {
          'unused': {'type': 'string'},
        },
      };
      expect(toGeminiSchema(schema), {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
        },
      });
    });

    test('drops validation keywords the subset does not understand', () {
      const schema = {
        'type': 'object',
        'properties': {
          'name': {'type': 'string', 'minLength': 1, 'pattern': '^[a-z]+\$'},
          'age': {'type': 'integer', 'minimum': 0, 'maximum': 150},
        },
      };
      expect(toGeminiSchema(schema), {
        'type': 'object',
        'properties': {
          'name': {'type': 'string'},
          'age': {'type': 'integer'},
        },
      });
    });

    test('keeps the keywords the subset does understand', () {
      const schema = {
        'type': 'array',
        'description': 'a list',
        'minItems': 1,
        'maxItems': 4,
        'items': {'type': 'string', 'format': 'date-time'},
      };
      expect(toGeminiSchema(schema), {
        'type': 'array',
        'description': 'a list',
        'minItems': 1,
        'maxItems': 4,
        'items': {'type': 'string', 'format': 'date-time'},
      });
    });

    test('inlines a local ref rather than forwarding it', () {
      const schema = {
        'type': 'object',
        r'$defs': {
          'score': {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'verdict': {
                'type': 'string',
                'enum': ['PASS', 'FAIL'],
              },
            },
          },
        },
        'properties': {
          'first': {r'$ref': r'#/$defs/score'},
          'second': {r'$ref': r'#/$defs/score'},
        },
      };
      final out = toGeminiSchema(schema)!;
      expect(allKeysDeep(out), isNot(contains(r'$ref')));
      expect(allKeysDeep(out), isNot(contains(r'$defs')));
      final properties = out['properties']! as Map<String, Object?>;
      const inlined = {
        'type': 'object',
        'properties': {
          'verdict': {
            'type': 'string',
            'enum': ['PASS', 'FAIL'],
          },
        },
      };
      expect(properties['first'], inlined);
      expect(properties['second'], inlined);
    });

    test('inlines a ref through the legacy definitions bucket too', () {
      const schema = {
        'type': 'object',
        'definitions': {
          'name': {'type': 'string'},
        },
        'properties': {
          'who': {r'$ref': '#/definitions/name'},
        },
      };
      expect(toGeminiSchema(schema), {
        'type': 'object',
        'properties': {
          'who': {'type': 'string'},
        },
      });
    });

    test('a sibling keyword beside a ref wins over the target', () {
      const schema = {
        'type': 'object',
        r'$defs': {
          'name': {'type': 'string', 'description': 'generic'},
        },
        'properties': {
          'who': {r'$ref': r'#/$defs/name', 'description': 'specific'},
        },
      };
      final out = toGeminiSchema(schema)!;
      final who = (out['properties']! as Map<String, Object?>)['who']!
          as Map<String, Object?>;
      expect(who['description'], 'specific');
    });

    test('gives up on a recursive ref instead of emitting one', () {
      const schema = {
        'type': 'object',
        r'$defs': {
          'node': {
            'type': 'object',
            'properties': {
              'child': {r'$ref': r'#/$defs/node'},
            },
          },
        },
        'properties': {
          'root': {r'$ref': r'#/$defs/node'},
        },
      };
      expect(toGeminiSchema(schema), isNull);
    });

    test('gives up on an unresolvable ref', () {
      const schema = {
        'type': 'object',
        'properties': {
          'who': {r'$ref': '#/components/schemas/Missing'},
        },
      };
      expect(toGeminiSchema(schema), isNull);
    });

    test('gives up on a genuine multi-type union', () {
      const schema = {
        'type': 'object',
        'properties': {
          'either': {
            'type': ['string', 'number'],
          },
        },
      };
      expect(toGeminiSchema(schema), isNull);
    });

    test('gives up on a boolean subschema', () {
      const schema = {
        'type': 'object',
        'properties': {'anything': true},
      };
      expect(toGeminiSchema(schema), isNull);
    });

    test('infers the type the subset insists on', () {
      expect(
        toGeminiSchema(const {
          'properties': {
            'a': {'type': 'string'},
          },
        }),
        {
          'type': 'object',
          'properties': {
            'a': {'type': 'string'},
          },
        },
      );
      expect(
        toGeminiSchema(const {
          'items': {'type': 'string'},
        }),
        {
          'type': 'array',
          'items': {'type': 'string'},
        },
      );
      expect(
        toGeminiSchema(const {
          'enum': ['PASS', 'FAIL'],
        }),
        {
          'type': 'string',
          'enum': ['PASS', 'FAIL'],
        },
      );
    });

    test('recurses through anyOf branches', () {
      const schema = {
        'anyOf': [
          {
            'type': 'object',
            'additionalProperties': false,
            'properties': {
              'a': {'type': 'string'},
            },
          },
          {
            'type': ['string', 'null'],
          },
        ],
      };
      expect(toGeminiSchema(schema), {
        'anyOf': [
          {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
          },
          {'type': 'string', 'nullable': true},
        ],
      });
    });

    test('an explicit nullable flag survives', () {
      expect(
        toGeminiSchema(const {'type': 'string', 'nullable': true}),
        {'type': 'string', 'nullable': true},
      );
    });

    test('the result shares no structure with the input', () {
      final out = toGeminiSchema(kJudgeJsonSchema)!;
      // The judge schema is a `const` map, so a translation that aliased it
      // would blow up here rather than quietly mutate a caller's constant.
      expect(() => out['required'] = <String>['changed'], returnsNormally);
      expect(
        (out['properties']! as Map<String, Object?>)..remove('changelog'),
        isNot(contains('changelog')),
      );
      expect(
        (kJudgeJsonSchema['properties']! as Map<String, Object?>).keys,
        contains('changelog'),
      );
    });
  });

  group('toOpenAiStrictSchema', () {
    test('every object forbids extra properties', () {
      final out = toOpenAiStrictSchema(kJudgeJsonSchema);
      final objects = objectSchemasDeep(out);
      expect(objects, hasLength(3));
      for (final object in objects) {
        expect(
          object['additionalProperties'],
          isFalse,
          reason: 'strict mode rejects an object without it',
        );
      }
    });

    test('required names every declared property', () {
      final out = toOpenAiStrictSchema(kJudgeJsonSchema);
      for (final object in objectSchemasDeep(out)) {
        final properties = object['properties']! as Map<String, Object?>;
        expect(object['required'], properties.keys.toList());
      }
    });

    test('adds both to an object that declared neither', () {
      const schema = {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          'b': {
            'type': 'object',
            'properties': {
              'c': {'type': 'string'},
            },
          },
        },
      };
      expect(toOpenAiStrictSchema(schema), {
        'type': 'object',
        'properties': {
          'a': {'type': 'string'},
          'b': {
            'type': 'object',
            'properties': {
              'c': {'type': 'string'},
            },
            'required': ['c'],
            'additionalProperties': false,
          },
        },
        'required': ['a', 'b'],
        'additionalProperties': false,
      });
    });

    test('completes a partial required list rather than trusting it', () {
      const schema = {
        'type': 'object',
        'required': ['a'],
        'properties': {
          'a': {'type': 'string'},
          'b': {'type': 'string'},
        },
      };
      final out = toOpenAiStrictSchema(schema);
      expect(out['required'], ['a', 'b']);
    });

    test('gives a property-less object the empty shape strict mode wants', () {
      expect(toOpenAiStrictSchema(const {'type': 'object'}), {
        'type': 'object',
        'properties': <String, Object?>{},
        'required': <String>[],
        'additionalProperties': false,
      });
    });

    test('treats a nullable object as an object', () {
      const schema = {
        'type': ['object', 'null'],
        'properties': {
          'a': {'type': 'string'},
        },
      };
      expect(toOpenAiStrictSchema(schema), {
        'type': ['object', 'null'],
        'properties': {
          'a': {'type': 'string'},
        },
        'required': ['a'],
        'additionalProperties': false,
      });
    });

    test('leaves nullable unions alone — strict mode speaks JSON Schema', () {
      final out = toOpenAiStrictSchema(kJudgeJsonSchema);
      final properties = out['properties']! as Map<String, Object?>;
      expect(
        (properties['improved_prompt']! as Map<String, Object?>)['type'],
        ['string', 'null'],
      );
      expect(
        (properties['improved_questions']! as Map<String, Object?>)['type'],
        ['array', 'null'],
      );
      expect(allKeysDeep(out), isNot(contains('nullable')));
    });

    test('applies the strict rules inside \$defs and keeps refs', () {
      const schema = {
        'type': 'object',
        r'$defs': {
          'score': {
            'type': 'object',
            'properties': {
              'verdict': {'type': 'string'},
            },
          },
        },
        'properties': {
          'first': {r'$ref': r'#/$defs/score'},
        },
      };
      final out = toOpenAiStrictSchema(schema);
      final defs = out[r'$defs']! as Map<String, Object?>;
      final score = defs['score']! as Map<String, Object?>;
      expect(score['required'], ['verdict']);
      expect(score['additionalProperties'], isFalse);
      expect(
        (out['properties']! as Map<String, Object?>)['first'],
        {r'$ref': r'#/$defs/score'},
      );
    });

    test('drops the meta keywords and re-derives additionalProperties', () {
      const schema = {
        r'$schema': 'https://json-schema.org/draft/2020-12/schema',
        r'$id': 'https://example.com/x.json',
        'type': 'object',
        'additionalProperties': true,
        'properties': {
          'a': {'type': 'string'},
        },
      };
      final out = toOpenAiStrictSchema(schema);
      expect(out.containsKey(r'$schema'), isFalse);
      expect(out.containsKey(r'$id'), isFalse);
      expect(out['additionalProperties'], isFalse);
    });

    test('recurses through anyOf branches', () {
      const schema = {
        'anyOf': [
          {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
          },
          {'type': 'string'},
        ],
      };
      expect(toOpenAiStrictSchema(schema), {
        'anyOf': [
          {
            'type': 'object',
            'properties': {
              'a': {'type': 'string'},
            },
            'required': ['a'],
            'additionalProperties': false,
          },
          {'type': 'string'},
        ],
      });
    });

    test('the result shares no structure with the input', () {
      final out = toOpenAiStrictSchema(kJudgeJsonSchema);
      expect(() => out['required'] = <String>['changed'], returnsNormally);
      final properties = out['properties']! as Map<String, Object?>;
      expect(() => properties.remove('changelog'), returnsNormally);
      expect(
        (kJudgeJsonSchema['properties']! as Map<String, Object?>).keys,
        contains('changelog'),
      );
    });
  });
}
