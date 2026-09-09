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

/// The real schema that exposed the bug, copied verbatim from
/// `prompt_improver`'s `lib/src/engine/judge.dart` (`kJudgeJsonSchema`).
///
/// It is here rather than imported because `prompt_improver` depends on
/// `ai_broker`, not the other way round. It is worth carrying anyway: it is
/// the schema a production run was actually built on, and it exercises every
/// awkward corner at once — `additionalProperties` at two nesting levels
/// (a 400 on Gemini), two nullable unions, an `enum`, `description` strings
/// and an array of objects.
///
/// Keep it in sync with the original whenever that changes.
const Map<String, Object?> kJudgeJsonSchema = {
  'type': 'object',
  'additionalProperties': false,
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
        'additionalProperties': false,
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
      'type': ['array', 'null'],
      'items': {
        'type': 'object',
        'additionalProperties': false,
        'required': ['q', 'expected'],
        'properties': {
          'q': {'type': 'string'},
          'expected': {'type': 'string'},
        },
      },
    },
    'improved_prompt': {
      'type': ['string', 'null'],
      'description': 'The full rewritten system prompt, or null to decline.',
    },
    'changelog': {
      'type': 'string',
      'description': 'Short bullet list of what changed and why.',
    },
  },
};

/// Every key name appearing anywhere in [node], at any depth, including keys
/// nested under `properties`. Used to assert that a keyword was removed from
/// the *whole* tree rather than only from its root.
Set<String> allKeysDeep(Object? node) {
  final out = <String>{};
  void walk(Object? value) {
    if (value is Map<String, Object?>) {
      for (final entry in value.entries) {
        out.add(entry.key);
        walk(entry.value);
      }
    } else if (value is List<Object?>) {
      value.forEach(walk);
    }
  }

  walk(node);
  return out;
}

/// Every object schema reachable from [node] — the ones OpenAI's strict mode
/// has requirements about. Includes [node] itself when it is one.
List<Map<String, Object?>> objectSchemasDeep(Object? node) {
  final out = <Map<String, Object?>>[];
  void walk(Object? value) {
    if (value is Map<String, Object?>) {
      if (value['type'] == 'object') out.add(value);
      value.values.forEach(walk);
    } else if (value is List<Object?>) {
      value.forEach(walk);
    }
  }

  walk(node);
  return out;
}
