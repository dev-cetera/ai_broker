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

/// Strips a leading and trailing markdown code fence from [text]. Model
/// output for "give me code" prompts usually arrives wrapped in
/// ```` ```lang\n...\n``` ````, even after an explicit "code only"
/// instruction. Call this on the broker's raw text before writing it to
/// a `.dart` / `.ts` / etc. file.
///
/// Behaviour:
///  - If the trimmed text starts with ```` ``` ```` (optionally followed
///    by a language tag on the same line), that opening fence line is
///    removed.
///  - If it then ends with ```` ``` ````, that closing fence is removed.
///  - Anything else is returned unchanged (after a `.trim()`).
///
/// Mirrors the inline stripping logic previously embedded in
/// df_generate_dart_models' Gemini path, lifted here so every
/// codegen-style caller can share it.
String stripCodeFence(String text) {
  var out = text.trim();
  if (!out.startsWith('```')) return out;
  final firstNewline = out.indexOf('\n');
  if (firstNewline == -1) return out;
  out = out.substring(firstNewline + 1);
  if (out.endsWith('```')) {
    out = out.substring(0, out.length - 3);
  }
  return out.trim();
}
