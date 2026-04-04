// ignore_for_file: dangling_library_doc_comments
/// Unit tests for RenderPretextLine supporting logic.
///
/// Three test layers:
///   1. _clipSpan       — InlineSpan slicer (pure Dart, no Flutter binding)
///   2. _advanceCursor  — normalisation-aware cursor advancement
///   3. Widget-level    — RenderPretextLine in a real pumpWidget
///
/// Run with:
///   flutter test test/pretext/pretext_proxy_test.dart

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_quill_pretext/src/editor/widgets/pretext_proxy.dart'
    show PretextRichText, advanceCursorForTest, clipSpanForTest;
import 'package:flutter_test/flutter_test.dart';

// ─── 1. _clipSpan ─────────────────────────────────────────────────────────────

void main() {
  // ── flat TextSpan ─────────────────────────────────────────────────────────

  group('clipSpan — flat TextSpan', () {
    const text = 'Hello, World!'; // 13 chars
    const span = TextSpan(text: text);

    test('full slice returns all text', () {
      expect(clipSpanForTest(span, 0, text.length).toPlainText(), text);
    });

    test('prefix slice', () {
      expect(clipSpanForTest(span, 0, 5).toPlainText(), 'Hello');
    });

    test('middle slice', () {
      expect(clipSpanForTest(span, 7, 12).toPlainText(), 'World');
    });

    test('empty slice returns empty span', () {
      expect(clipSpanForTest(span, 5, 5).toPlainText(), '');
    });

    test('out-of-range end is clamped gracefully', () {
      expect(clipSpanForTest(span, 0, 100).toPlainText(), text);
    });
  });

  // ── nested TextSpan (Quill-like: plain + bold + plain) ────────────────────

  group('clipSpan — nested TextSpan', () {
    // "Hello " (plain) + "world" (bold) + " foo\n" (plain)
    // toPlainText() = "Hello world foo\n" (16 chars)
    const span = TextSpan(
      style: TextStyle(fontSize: 16),
      children: [
        TextSpan(text: 'Hello '),
        TextSpan(
          text: 'world',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        TextSpan(text: ' foo\n'),
      ],
    );

    test('slice within first child', () {
      expect(clipSpanForTest(span, 0, 5).toPlainText(), 'Hello');
    });

    test('slice exactly the bold child', () {
      final result = clipSpanForTest(span, 6, 11) as TextSpan;
      expect(result.toPlainText(), 'world');
      final bold = result.children
          ?.whereType<TextSpan>()
          .firstWhere((s) => s.text == 'world', orElse: () => const TextSpan());
      expect(bold?.style?.fontWeight, FontWeight.bold);
    });

    test('slice spanning first child and bold child', () {
      expect(clipSpanForTest(span, 0, 11).toPlainText(), 'Hello world');
    });

    test('slice spanning bold child and trailing text', () {
      expect(clipSpanForTest(span, 6, 15).toPlainText(), 'world foo');
    });

    test('trailing newline slice', () {
      expect(clipSpanForTest(span, 15, 16).toPlainText(), '\n');
    });

    test('full span preserves all text', () {
      expect(clipSpanForTest(span, 0, 16).toPlainText(), 'Hello world foo\n');
    });
  });

  // ── recognizer preservation ───────────────────────────────────────────────

  group('clipSpan — recognizer preservation', () {
    test('recognizer is preserved when slicing the link child', () {
      final recognizer = TapGestureRecognizer()..onTap = () {};
      addTearDown(recognizer.dispose);

      final span = TextSpan(
        children: [
          const TextSpan(text: 'plain '),
          TextSpan(
            text: 'link',
            recognizer: recognizer,
            style: const TextStyle(color: Colors.blue),
          ),
          const TextSpan(text: ' text'),
        ],
      );

      final result = clipSpanForTest(span, 6, 10) as TextSpan;
      final linkChild = result.children
          ?.whereType<TextSpan>()
          .firstWhere((s) => s.text == 'link', orElse: () => const TextSpan());
      expect(linkChild?.recognizer, recognizer);
    });

    test('recognizer is absent when slicing outside the link child', () {
      final recognizer = TapGestureRecognizer()..onTap = () {};
      addTearDown(recognizer.dispose);

      final span = TextSpan(
        children: [
          const TextSpan(text: 'plain '),
          TextSpan(text: 'link', recognizer: recognizer),
          const TextSpan(text: ' text'),
        ],
      );

      final result = clipSpanForTest(span, 11, 15) as TextSpan; // " tex"
      final anyWithRecognizer = (result.children ?? [])
          .whereType<TextSpan>()
          .any((s) => s.recognizer != null);
      expect(anyWithRecognizer, false);
    });
  });

  // ─── 2. _advanceCursor ────────────────────────────────────────────────────

  group('advanceCursor — normalisation-aware', () {
    test('identical strings advance by lineText.length', () {
      expect(advanceCursorForTest('hello world', 0, 'hello world'), 11);
    });

    test('cursor starts mid-string', () {
      expect(advanceCursorForTest('hello world', 6, 'world'), 11);
    });

    test('trailing newline in plainText stays unconsumed after lineText', () {
      // Quill paragraph ends with \n; normalised text strips it.
      // advanceCursor should consume 'hello' and leave cursor at 5 (at \n),
      // not 6 — the \n is left for the safety-remainder check.
      expect(advanceCursorForTest('hello\n', 0, 'hello'), 5);
    });

    test('double space in plainText collapsed to single in lineText', () {
      // normalizeWhitespaceNormal: "foo  bar" → "foo bar"
      // The extra space is skipped in plainText.
      expect(advanceCursorForTest('foo  bar', 0, 'foo bar'), 8);
    });

    test('empty lineText makes no progress', () {
      expect(advanceCursorForTest('hello', 0, ''), 0);
      expect(advanceCursorForTest('hello', 3, ''), 3);
    });

    test('cursor does not exceed plainText.length', () {
      // lineText longer than remaining plainText → capped
      expect(advanceCursorForTest('hi', 0, 'hi there'), 2);
    });
  });

  // ─── 3. Widget-level ─────────────────────────────────────────────────────

  group('PretextRichText widget — line count and height', () {
    Future<Size> pumpPretext(
      WidgetTester tester,
      String text, {
      double columnWidth = 200.0,
      double fontSize = 14.0,
    }) async {
      final style = TextStyle(fontSize: fontSize, fontFamily: 'Ahem');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(
                width: columnWidth,
                child: PretextRichText(
                  textSpan: TextSpan(text: text, style: style),
                  textStyle: style,
                  textAlign: TextAlign.left,
                  textDirection: TextDirection.ltr,
                  strutStyle: StrutStyle.fromTextStyle(style),
                  locale: const Locale('en'),
                  textScaler: TextScaler.noScaling,
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      return tester
          .renderObject<RenderBox>(find.byType(PretextRichText))
          .size;
    }

    testWidgets('short text that fits on one line has height ≈ one lineHeight',
        (tester) async {
      // Ahem: each char = 1em wide × 1em tall.
      // "hello" = 5 × 10 = 50px < 200px column → one line.
      final size =
          await pumpPretext(tester, 'hello', columnWidth: 200, fontSize: 10);
      expect(size.height, closeTo(10.0, 2.0));
      expect(size.width, 200.0);
    });

    testWidgets('text wider than column wraps to multiple lines',
        (tester) async {
      // Ahem 10px: "aaa bbb ccc" = 110px > 60px column → must wrap.
      final size = await pumpPretext(tester, 'aaa bbb ccc',
          columnWidth: 60, fontSize: 10);
      expect(size.height, greaterThan(10.0));
    });

    testWidgets('trailing newline does not add a spurious extra line',
        (tester) async {
      // Quill paragraphs end with \n; this must NOT add a blank line.
      final withNl =
          await pumpPretext(tester, 'hello\n', columnWidth: 200, fontSize: 10);
      final withoutNl =
          await pumpPretext(tester, 'hello', columnWidth: 200, fontSize: 10);
      expect(withNl.height, closeTo(withoutNl.height, 2.0));
    });

    testWidgets('long text renders without overflow errors', (tester) async {
      const long = "Garry's Mod's first (free) release hit on Christmas Eve 2004, "
          'and the game has maintained a presence on Steam since 2006, '
          'where it currently sells for £5.99.\n';
      await expectLater(
        () => pumpPretext(tester, long, columnWidth: 300, fontSize: 14),
        returnsNormally,
      );
    });
  });

  // ─── 4. Cursor-drift regression ───────────────────────────────────────────
  //
  // Pin per-line clip positions for a multi-span paragraph to catch the
  // "connec"/"t" style mid-word split regression.

  group('clipSpan + advanceCursor — cursor drift regression', () {
    // "Hello " + "world" (bold) + " foo bar baz\n"
    // toPlainText() = "Hello world foo bar baz\n" (24 chars)
    // Pretext normalises → "Hello world foo bar baz" (23 chars, no \n)
    // Simulated breaks:  line1="Hello world foo ", line2="bar baz"
    const span = TextSpan(
      style: TextStyle(fontSize: 14),
      children: [
        TextSpan(text: 'Hello '),
        TextSpan(
          text: 'world',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        TextSpan(text: ' foo bar baz\n'),
      ],
    );
    const plain = 'Hello world foo bar baz\n';

    test('line 1 clip is correct', () {
      const line1 = 'Hello world foo ';
      final end1 = advanceCursorForTest(plain, 0, line1);
      expect(end1, line1.length); // 16 — no drift
      expect(clipSpanForTest(span, 0, end1).toPlainText(), line1);
    });

    test('line 2 starts at correct offset without drift', () {
      const line1 = 'Hello world foo ';
      const line2 = 'bar baz';
      final end1 = advanceCursorForTest(plain, 0, line1);
      final end2 = advanceCursorForTest(plain, end1, line2);
      expect(end2, end1 + line2.length); // 23 — accumulates correctly
      expect(clipSpanForTest(span, end1, end2).toPlainText(), line2);
    });

    test('trailing \\n remainder is whitespace-only → discarded', () {
      const line1 = 'Hello world foo ';
      const line2 = 'bar baz';
      final end2 = advanceCursorForTest(
        plain,
        advanceCursorForTest(plain, 0, line1),
        line2,
      );
      final remainder = plain.substring(end2);
      expect(remainder, '\n');
      expect(remainder.trim(), isEmpty);
    });

    test('bold child is preserved when sliced mid-span', () {
      // "world" is in chars [6, 11). Clip to get just that child.
      final end = advanceCursorForTest(plain, 0, 'Hello world'); // = 11
      final result = clipSpanForTest(span, 6, end) as TextSpan;
      final bold = result.children
          ?.whereType<TextSpan>()
          .firstWhere(
            (s) => s.text != null && s.text!.contains('world'),
            orElse: () => const TextSpan(),
          );
      expect(bold?.style?.fontWeight, FontWeight.bold);
    });
  });
}
