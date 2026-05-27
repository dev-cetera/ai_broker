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

void main() {
  group('stripCodeFence', () {
    test('strips a fence with a language tag', () {
      const input = '```dart\nvoid main() {}\n```';
      expect(stripCodeFence(input), 'void main() {}');
    });

    test('strips a fence without a language tag', () {
      const input = '```\nhello\n```';
      expect(stripCodeFence(input), 'hello');
    });

    test('trims surrounding whitespace before checking for a fence', () {
      const input = '   \n\n```dart\nx\n```\n\n   ';
      expect(stripCodeFence(input), 'x');
    });

    test('returns plain text unchanged but trimmed', () {
      expect(stripCodeFence('  hello world  '), 'hello world');
    });

    test('returns empty string unchanged', () {
      expect(stripCodeFence(''), '');
    });

    test('preserves inner triple-backticks when only the outer ones fence', () {
      const input = '```md\nuse ```code``` like this\n```';
      expect(stripCodeFence(input), 'use ```code``` like this');
    });

    test('returns input unchanged when there is an opening fence but no '
        'newline', () {
      const input = '```dart void main() {}```';
      expect(stripCodeFence(input), input);
    });

    test('removes only the opening fence when the closing fence is missing', () {
      const input = '```dart\nvoid main() {}';
      expect(stripCodeFence(input), 'void main() {}');
    });

    test('preserves blank lines inside the body', () {
      const input = '```\nline one\n\nline three\n```';
      expect(stripCodeFence(input), 'line one\n\nline three');
    });

    test('does not touch text that starts with a single backtick', () {
      expect(stripCodeFence('`inline`'), '`inline`');
    });

    test('handles multi-line body with multiple language hints', () {
      const input = '```typescript\nconst x = 1;\nconst y = 2;\n```';
      expect(stripCodeFence(input), 'const x = 1;\nconst y = 2;');
    });
  });
}
