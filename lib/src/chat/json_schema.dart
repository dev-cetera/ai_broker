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

// Structured-output schema translation.
//
// `ChatRequest.jsonSchema` is one JSON Schema written once by the caller, but
// no two providers accept the same dialect — and they disagree in opposite
// directions:
//
//   * Anthropic takes the schema verbatim in `output_config.format`.
//   * Gemini takes an **OpenAPI 3.0 subset**, where `additionalProperties` is
//     a hard 400 (`Unknown name "additionalProperties" at
//     'generation_config.response_schema'`) and nullability is a `nullable`
//     flag rather than a `['string', 'null']` union.
//   * OpenAI's `strict` mode **requires** `additionalProperties: false` on
//     every object and every property named in `required`.
//
// These are pure functions on purpose: no I/O, no provider objects, nothing to
// stub. The brokers call them while building a payload.

/// Translates a JSON Schema into the OpenAPI 3.0 subset Gemini's
/// `generationConfig.responseSchema` accepts.
///
/// What it does:
///  * drops `additionalProperties` — Gemini rejects the request outright when
///    it is present, which is the bug this exists to fix,
///  * drops the meta keywords (`$schema`, `$id`, `$defs`, `definitions`) and
///    inlines any local `$ref` that points into them,
///  * rewrites a nullable union — `type: ['string', 'null']` — as
///    `type: 'string'` plus `nullable: true`,
///  * keeps `type`, `properties`, `items`, `required`, `enum`, `description`,
///    and the handful of other keywords the subset understands
///    (`format`, `nullable`, `minItems`, `maxItems`, `propertyOrdering`,
///    `anyOf`), recursing through `properties`, `items` and `anyOf`,
///  * drops every other keyword (`minLength`, `pattern`, `maximum`, …) rather
///    than passing along something Gemini will reject.
///
/// Returns **null** when the schema cannot be expressed safely — a recursive
/// or unresolvable `$ref`, or a genuine multi-type union such as
/// `['string', 'number']`. A null result is not a failure to report: the
/// caller should still ask for `responseMimeType: 'application/json'` and
/// accept unconstrained JSON, which beats both prose and a 400.
///
/// The input is never mutated; everything returned is a fresh copy, so a
/// `const` schema can be passed in safely.
Map<String, Object?>? toGeminiSchema(Map<String, Object?> schema) {
  try {
    return _toGemini(schema, _collectDefs(schema), const <String>{});
  } on _UnsupportedSchema {
    return null;
  }
}

/// Rewrites a JSON Schema so OpenAI's `response_format.json_schema` accepts it
/// with `strict: true`.
///
/// Strict mode wants the exact opposite of Gemini: every object must carry
/// `additionalProperties: false` and must name **every** declared property in
/// `required`. Both are added where the caller left them out rather than
/// assumed to be there — a schema written for Anthropic or Gemini otherwise
/// 400s here.
///
/// Objects that declare no `properties` get an empty map, an empty `required`
/// and `additionalProperties: false`, which is the shape strict mode expects.
/// A schema-valued `additionalProperties` ("extra keys must look like this")
/// is replaced by `false` rather than forwarded — strict mode has no way to
/// express it, and a caller who wanted open objects cannot have strict mode.
/// The meta keywords `$schema` and `$id` are dropped; `$ref` and `$defs` are
/// left alone because strict mode supports them.
///
/// The input is never mutated; everything returned is a fresh copy, so a
/// `const` schema can be passed in safely.
Map<String, Object?> toOpenAiStrictSchema(Map<String, Object?> schema) =>
    _toOpenAi(schema);

// -----------------------------------------------------------------------------
// Gemini
// -----------------------------------------------------------------------------

/// Keywords copied straight across. [_toGemini] handles `type`, `enum`,
/// `required`, `properties`, `items` and `anyOf` itself; everything not listed
/// in either place is dropped.
const _kGeminiPassthrough = <String>{
  'description',
  'format',
  'minItems',
  'maxItems',
  'propertyOrdering',
};

/// Thrown internally when a schema has no safe translation. Never escapes
/// [toGeminiSchema], which turns it into a null result.
class _UnsupportedSchema implements Exception {
  final String reason;

  const _UnsupportedSchema(this.reason);

  @override
  String toString() => 'Unsupported for Gemini: $reason';
}

Map<String, Object?> _toGemini(
  Map<String, Object?> node,
  Map<String, Map<String, Object?>> defs,
  Set<String> active,
) {
  // A `$ref` is inlined rather than forwarded: Gemini has no `$defs` to
  // resolve it against. Sibling keywords override the target, per 2020-12.
  final ref = node[r'$ref'];
  if (ref != null) {
    if (ref is! String) {
      throw const _UnsupportedSchema(r'a non-string $ref');
    }
    if (active.contains(ref)) {
      throw _UnsupportedSchema('a recursive \$ref ($ref)');
    }
    final target = defs[ref];
    if (target == null) {
      throw _UnsupportedSchema('an unresolvable \$ref ($ref)');
    }
    final inlined = <String, Object?>{...target};
    for (final entry in node.entries) {
      if (entry.key == r'$ref') continue;
      inlined[entry.key] = entry.value;
    }
    return _toGemini(inlined, defs, {...active, ref});
  }

  final out = <String, Object?>{};
  var nullable = node['nullable'] == true;

  // `type: ['string', 'null']` is how JSON Schema spells nullability and how
  // the judge schema spells `improved_prompt`. Gemini spells it with a flag.
  final rawType = node['type'];
  String? type;
  if (rawType is String) {
    if (rawType == 'null') {
      throw const _UnsupportedSchema("a bare 'null' type");
    }
    type = rawType;
  } else if (rawType != null) {
    final union = _asList(rawType);
    if (union == null) {
      throw const _UnsupportedSchema('a type that is neither string nor list');
    }
    final named = <String>[];
    for (final entry in union) {
      if (entry is! String) {
        throw const _UnsupportedSchema('a non-string entry in a type union');
      }
      if (entry == 'null') {
        nullable = true;
        continue;
      }
      named.add(entry);
    }
    if (named.isEmpty) {
      throw const _UnsupportedSchema("a 'null'-only type union");
    }
    if (named.length > 1) {
      throw _UnsupportedSchema('a multi-type union (${named.join(' | ')})');
    }
    type = named.single;
  }

  final properties = _asMap(node['properties']);
  final items = _asMap(node['items']);
  final enumValues = _asList(node['enum']);
  final anyOf = _asList(node['anyOf']);

  // Gemini wants a type on every node. Infer the obvious ones rather than
  // emitting a typeless schema it will reject.
  if (type == null) {
    if (properties != null) {
      type = 'object';
    } else if (items != null) {
      type = 'array';
    } else if (enumValues != null && enumValues.every((v) => v is String)) {
      type = 'string';
    }
  }

  if (type != null) out['type'] = type;
  if (nullable) out['nullable'] = true;

  for (final key in _kGeminiPassthrough) {
    if (node.containsKey(key)) out[key] = _deepCopy(node[key]);
  }

  if (enumValues != null) out['enum'] = _deepCopy(enumValues);

  final required = _asList(node['required']);
  if (required != null) {
    out['required'] = <String>[for (final key in required) key.toString()];
  }

  if (properties != null) {
    out['properties'] = <String, Object?>{
      for (final entry in properties.entries)
        entry.key: _toGemini(_schemaOf(entry.value), defs, active),
    };
  }
  if (items != null) out['items'] = _toGemini(items, defs, active);
  if (anyOf != null) {
    out['anyOf'] = <Object?>[
      for (final branch in anyOf) _toGemini(_schemaOf(branch), defs, active),
    ];
  }

  return out;
}

/// Indexes every local definition by the `$ref` pointer that would name it, so
/// [_toGemini] can inline one without walking the tree again.
Map<String, Map<String, Object?>> _collectDefs(Map<String, Object?> root) {
  final out = <String, Map<String, Object?>>{};
  void harvest(String prefix, Object? bucket) {
    final map = _asMap(bucket);
    if (map == null) return;
    for (final entry in map.entries) {
      final schema = _asMap(entry.value);
      if (schema != null) out['$prefix/${entry.key}'] = schema;
    }
  }

  harvest(r'#/$defs', root[r'$defs']);
  harvest('#/definitions', root['definitions']);
  harvest('#/components/schemas', _asMap(root['components'])?['schemas']);
  return out;
}

/// A schema position that has to hold an object. Boolean schemas (`true` /
/// `false`) and other JSON values have no OpenAPI equivalent.
Map<String, Object?> _schemaOf(Object? value) {
  final map = _asMap(value);
  if (map == null) {
    throw const _UnsupportedSchema('a non-object subschema');
  }
  return map;
}

// -----------------------------------------------------------------------------
// OpenAI
// -----------------------------------------------------------------------------

/// Keys whose value is a map **of** subschemas.
const _kOpenAiSchemaMaps = <String>{'properties', r'$defs', 'definitions'};

/// Keys whose value is a single subschema.
const _kOpenAiSchemaNodes = <String>{'items', 'not'};

/// Keys whose value is a list of subschemas.
const _kOpenAiSchemaLists = <String>{
  'anyOf',
  'oneOf',
  'allOf',
  'prefixItems',
};

/// Meta keywords no provider reads, plus `additionalProperties`, which is
/// re-derived below rather than trusted.
const _kOpenAiDropped = <String>{r'$schema', r'$id', 'additionalProperties'};

Map<String, Object?> _toOpenAi(Map<String, Object?> node) {
  final out = <String, Object?>{};
  for (final entry in node.entries) {
    final key = entry.key;
    final value = entry.value;
    if (_kOpenAiDropped.contains(key)) continue;

    if (_kOpenAiSchemaMaps.contains(key)) {
      final map = _asMap(value);
      if (map != null) {
        out[key] = <String, Object?>{
          for (final child in map.entries)
            child.key: _toOpenAiChild(child.value),
        };
        continue;
      }
    } else if (_kOpenAiSchemaNodes.contains(key)) {
      final map = _asMap(value);
      if (map != null) {
        out[key] = _toOpenAi(map);
        continue;
      }
    } else if (_kOpenAiSchemaLists.contains(key)) {
      final list = _asList(value);
      if (list != null) {
        out[key] = <Object?>[for (final branch in list) _toOpenAiChild(branch)];
        continue;
      }
    }
    out[key] = _deepCopy(value);
  }

  // The two things strict mode will not infer for you.
  if (_isObjectSchema(node)) {
    final properties = _asMap(out['properties']) ?? const <String, Object?>{};
    out['properties'] = properties;
    out['required'] = <String>[...properties.keys];
    out['additionalProperties'] = false;
  }
  return out;
}

Object? _toOpenAiChild(Object? value) {
  final map = _asMap(value);
  return map == null ? _deepCopy(value) : _toOpenAi(map);
}

/// True for anything strict mode treats as an object — including a nullable
/// one (`type: ['object', 'null']`) and an untyped node that declares
/// `properties`.
bool _isObjectSchema(Map<String, Object?> node) {
  final type = node['type'];
  if (type == 'object') return true;
  final union = _asList(type);
  if (union != null) return union.contains('object');
  return type == null && _asMap(node['properties']) != null;
}

// -----------------------------------------------------------------------------
// Shared
// -----------------------------------------------------------------------------

/// Normalises any JSON map — `jsonDecode` hands back `Map<String, dynamic>`,
/// literals in Dart source are `Map<String, Object?>` — to one key type.
/// Returns null for anything that is not a map.
Map<String, Object?>? _asMap(Object? value) {
  if (value is Map<String, Object?>) return value;
  if (value is Map<Object?, Object?>) {
    return value.map((k, v) => MapEntry(k.toString(), v));
  }
  return null;
}

List<Object?>? _asList(Object? value) => value is List<Object?> ? value : null;

/// Copies nested JSON so nothing in the result aliases the caller's schema —
/// which may well be `const`, and so unmodifiable.
Object? _deepCopy(Object? value) {
  final map = _asMap(value);
  if (map != null) {
    return <String, Object?>{
      for (final entry in map.entries) entry.key: _deepCopy(entry.value),
    };
  }
  final list = _asList(value);
  if (list != null) {
    return <Object?>[for (final entry in list) _deepCopy(entry)];
  }
  return value;
}
