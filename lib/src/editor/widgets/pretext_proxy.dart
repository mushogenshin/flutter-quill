// ignore_for_file: dangling_library_doc_comments
/// Pretext-driven line renderer for flutter_quill_pretext.
///
/// Drop-in replacement for [RichTextProxy] + [RichText] in text_line.dart.
/// Instead of delegating line breaking to Flutter's [RenderParagraph], it
/// accepts a [PretextLineBreaker] callback that computes break offsets using
/// the Pretext engine. Each logical line is then painted with an individually
/// laid-out [TextPainter], which powers caret / selection / hit-testing via
/// the same [RenderContentProxyBox] interface used by [RenderParagraphProxy].
///
/// ── Integration pattern ──────────────────────────────────────────────────
///
/// Wrap your [QuillEditor] with [PretextLineBreakerScope]:
///
///   PretextLineBreakerScope(
///     lineBreaker: (text, style, maxWidth) {
///       final prepared = prepareTextWithSegments(text, style);
///       final result   = layoutWithLines(prepared, maxWidth, lineHeight);
///       var offset = 0;
///       return result.lines.map((l) { offset += l.text.length; return offset; }).toList();
///     },
///     child: QuillEditor.basic(controller: controller),
///   )
///
/// When no [PretextLineBreakerScope] is present, [TextLine] transparently
/// falls back to the original [RichText] path — no behavior change.
///
/// ── TextSpan slicing ─────────────────────────────────────────────────────
///
/// Pretext returns character-offset break points for the line's PLAIN TEXT.
/// We then slice the rich [InlineSpan] tree at those offsets so each line
/// gets a [TextPainter] with the correct spans (bold, italic, links, etc.).
/// [WidgetSpan]s (inline embeds) are preserved whole if they fall within the
/// line range; they count as one character in the offset arithmetic.
///
/// ── RenderContentProxyBox implementation ─────────────────────────────────
///
/// The four methods Quill's selection / caret machinery depends on are:
///   • getPositionForOffset  — tap → document offset (hit-testing)
///   • getOffsetForCaret     — document offset → pixel (caret painting)
///   • getBoxesForSelection  — selection range → highlight rects
///   • getWordBoundary       — double-tap word select
///
/// Each is implemented by binary-searching to the correct line and delegating
/// to that line's [TextPainter], then adjusting offsets / y-coordinates.

import 'dart:ui' as ui show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'box.dart';

// ─── Public API ───────────────────────────────────────────────────────────────

/// Computes Pretext line-break offsets for [text] rendered with [style] inside
/// a column of [maxWidth] pixels.
///
/// Returns a list of EXCLUSIVE end offsets into [text] — one per line.
/// The last entry should equal (or be close to) [text.length].
///
/// Example return value for a two-line paragraph: `[28, 56]`.
typedef PretextLineBreaker = List<int> Function(
  String text,
  TextStyle style,
  double maxWidth,
);

/// InheritedWidget that makes a [PretextLineBreaker] available to every
/// [TextLine] widget in the subtree without explicit parameter threading.
///
/// Place this above [QuillEditor] in the widget tree.  [TextLine.build] calls
/// [PretextLineBreakerScope.of] and, when non-null, switches to the Pretext
/// rendering path; otherwise it falls back to the original [RichText] path.
class PretextLineBreakerScope extends InheritedWidget {
  const PretextLineBreakerScope({
    required this.lineBreaker,
    required super.child,
    super.key,
  });

  final PretextLineBreaker lineBreaker;

  /// Returns the nearest [PretextLineBreaker] from the widget tree, or null
  /// if no [PretextLineBreakerScope] has been placed above this context.
  static PretextLineBreaker? of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<PretextLineBreakerScope>()
        ?.lineBreaker;
  }

  @override
  bool updateShouldNotify(PretextLineBreakerScope old) =>
      old.lineBreaker != lineBreaker;
}

// ─── Widget ───────────────────────────────────────────────────────────────────

/// Replacement for [RichTextProxy] + [RichText].
///
/// Produces a [RenderPretextLine] that uses [lineBreaker] to determine where
/// lines end and paints each line with its own [TextPainter].
class PretextRichText extends LeafRenderObjectWidget {
  const PretextRichText({
    required this.textSpan,
    required this.textStyle,
    required this.textAlign,
    required this.textDirection,
    required this.strutStyle,
    required this.locale,
    required this.textScaler,
    required this.lineBreaker,
    super.key,
  });

  final InlineSpan textSpan;
  final TextStyle textStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final StrutStyle strutStyle;
  final Locale locale;
  final TextScaler textScaler;
  final PretextLineBreaker lineBreaker;

  @override
  RenderPretextLine createRenderObject(BuildContext context) {
    return RenderPretextLine(
      textSpan: textSpan,
      textStyle: textStyle,
      textAlign: textAlign,
      textDirection: textDirection,
      strutStyle: strutStyle,
      locale: locale,
      textScaler: textScaler,
      lineBreaker: lineBreaker,
    );
  }

  @override
  void updateRenderObject(
      BuildContext context, covariant RenderPretextLine renderObject) {
    renderObject
      ..textSpan = textSpan
      ..textStyle = textStyle
      ..textAlign = textAlign
      ..textDirection = textDirection
      ..strutStyle = strutStyle
      ..locale = locale
      ..textScaler = textScaler
      ..lineBreaker = lineBreaker;
  }
}

// ─── RenderObject ─────────────────────────────────────────────────────────────

/// A [RenderBox] that implements [RenderContentProxyBox] using Pretext line
/// breaks instead of Flutter's [RenderParagraph].
///
/// Layout:
///   1. Call [lineBreaker] with the span's plain text + constraints.maxWidth.
///   2. Slice the rich [InlineSpan] at the returned break offsets.
///   3. Build one [TextPainter] per line, laid out with NO maxWidth constraint
///      (identical to [pretext_article_view.dart] convention — the line text is
///      already broken; re-constraining it would let Flutter re-break it).
///   4. Report size as (maxWidth, lineHeight × lineCount).
///
/// Paint: paint each [TextPainter] at Offset(0, lineIndex × lineHeight).
///
/// Position queries: binary-search to the correct line, delegate to that
/// line's [TextPainter], and adjust the returned offset / rect by the line's
/// character start offset or y-position.
class RenderPretextLine extends RenderBox implements RenderContentProxyBox {
  RenderPretextLine({
    required InlineSpan textSpan,
    required TextStyle textStyle,
    required TextAlign textAlign,
    required TextDirection textDirection,
    required StrutStyle strutStyle,
    required Locale locale,
    required TextScaler textScaler,
    required PretextLineBreaker lineBreaker,
  })  : _textSpan = textSpan,
        _lineBreaker = lineBreaker,
        // Prototype painter: measures a single space to derive preferredLineHeight
        // without running a full layout. Same technique as RenderParagraphProxy.
        _prototypePainter = TextPainter(
          text: TextSpan(text: ' ', style: textStyle),
          textAlign: textAlign,
          textDirection: textDirection,
          textScaler: textScaler,
          strutStyle: strutStyle,
          locale: locale,
        );

  // ── Fields ─────────────────────────────────────────────────────────────────

  InlineSpan _textSpan;
  PretextLineBreaker _lineBreaker;
  final TextPainter _prototypePainter;

  /// One painter per Pretext line, laid out at unconstrained width.
  List<TextPainter> _linePainters = [];

  /// Character offset of the FIRST character in each line (into the span's
  /// plain text). _lineStartOffsets[i] is the start of line i.
  List<int> _lineStartOffsets = [];

  /// Total character count of the span's plain text — used in getBoxesForSelection.
  int _totalLength = 0;

  // ── Setters (each triggers relayout) ──────────────────────────────────────

  set textSpan(InlineSpan value) {
    if (_textSpan == value) return;
    _textSpan = value;
    markNeedsLayout();
  }

  set lineBreaker(PretextLineBreaker value) {
    if (_lineBreaker == value) return;
    _lineBreaker = value;
    markNeedsLayout();
  }

  set textStyle(TextStyle value) {
    if (_prototypePainter.text!.style == value) return;
    _prototypePainter.text = TextSpan(text: ' ', style: value);
    markNeedsLayout();
  }

  set textAlign(TextAlign value) {
    if (_prototypePainter.textAlign == value) return;
    _prototypePainter.textAlign = value;
    markNeedsLayout();
  }

  set textDirection(TextDirection value) {
    if (_prototypePainter.textDirection == value) return;
    _prototypePainter.textDirection = value;
    markNeedsLayout();
  }

  set textScaler(TextScaler value) {
    if (_prototypePainter.textScaler == value) return;
    _prototypePainter.textScaler = value;
    markNeedsLayout();
  }

  set strutStyle(StrutStyle value) {
    if (_prototypePainter.strutStyle == value) return;
    _prototypePainter.strutStyle = value;
    markNeedsLayout();
  }

  set locale(Locale value) {
    if (_prototypePainter.locale == value) return;
    _prototypePainter.locale = value;
    markNeedsLayout();
  }

  // ── RenderContentProxyBox ──────────────────────────────────────────────────

  @override
  double get preferredLineHeight {
    // Use the prototype painter — layout() is called inside performLayout,
    // but preferredLineHeight is also queried before layout for sizing hints.
    // The prototype painter is always kept in sync with the current style.
    if (!_prototypePainter.debugDisposed) {
      _prototypePainter.layout();
    }
    return _prototypePainter.preferredLineHeight;
  }

  @override
  Offset getOffsetForCaret(TextPosition position, Rect caretPrototype) {
    if (_linePainters.isEmpty) return Offset.zero;
    final idx = _lineIndexForOffset(position.offset);
    final localOffset = position.offset - _lineStartOffsets[idx];
    final local = _linePainters[idx]
        .getOffsetForCaret(TextPosition(offset: localOffset), caretPrototype);
    return local + Offset(0, idx * preferredLineHeight);
  }

  @override
  TextPosition getPositionForOffset(Offset offset) {
    if (_linePainters.isEmpty) return const TextPosition(offset: 0);
    final lh = preferredLineHeight;
    // Clamp line index to valid range.
    final idx = (offset.dy / lh).floor().clamp(0, _linePainters.length - 1);
    // Query only the x-coordinate — the painter is a single logical line.
    final local =
        _linePainters[idx].getPositionForOffset(Offset(offset.dx, 0));
    return TextPosition(offset: _lineStartOffsets[idx] + local.offset);
  }

  @override
  double? getFullHeightForCaret(TextPosition position) => preferredLineHeight;

  @override
  TextRange getWordBoundary(TextPosition position) {
    if (_linePainters.isEmpty) return const TextRange(start: 0, end: 0);
    final idx = _lineIndexForOffset(position.offset);
    final localOffset = position.offset - _lineStartOffsets[idx];
    final local = _linePainters[idx]
        .getWordBoundary(TextPosition(offset: localOffset));
    return TextRange(
      start: local.start + _lineStartOffsets[idx],
      end: local.end + _lineStartOffsets[idx],
    );
  }

  @override
  List<TextBox> getBoxesForSelection(TextSelection selection) {
    final lh = preferredLineHeight;
    final boxes = <TextBox>[];
    for (var i = 0; i < _linePainters.length; i++) {
      final lineStart = _lineStartOffsets[i];
      final lineEnd = i + 1 < _lineStartOffsets.length
          ? _lineStartOffsets[i + 1]
          : _totalLength;
      // Check overlap with selection.
      if (selection.end <= lineStart || selection.start >= lineEnd) continue;
      final localStart = (selection.start - lineStart).clamp(0, lineEnd - lineStart);
      final localEnd = (selection.end - lineStart).clamp(0, lineEnd - lineStart);
      if (localStart >= localEnd) continue;
      final localSel =
          TextSelection(baseOffset: localStart, extentOffset: localEnd);
      for (final box in _linePainters[i].getBoxesForSelection(
        localSel,
        boxHeightStyle: ui.BoxHeightStyle.max,
        boxWidthStyle: ui.BoxWidthStyle.tight,
      )) {
        // Shift each box down by this line's y-offset.
        boxes.add(TextBox.fromLTRBD(
          box.left,
          box.top + i * lh,
          box.right,
          box.bottom + i * lh,
          box.direction,
        ));
      }
    }
    return boxes;
  }

  // ── Layout & Paint ─────────────────────────────────────────────────────────

  @override
  void performLayout() {
    // 1. Layout prototype to get the authoritative line height.
    _prototypePainter.layout(
        minWidth: constraints.minWidth, maxWidth: constraints.maxWidth);
    final lh = _prototypePainter.preferredLineHeight;

    // 2. Extract plain text and call the Pretext line breaker.
    final plainText = _textSpan.toPlainText(includeSemanticsLabels: false);
    _totalLength = plainText.length;

    if (plainText.isEmpty) {
      _disposeLinePainters();
      _linePainters = [];
      _lineStartOffsets = [];
      size = constraints.constrain(Size(constraints.maxWidth, lh));
      return;
    }

    final breakStyle = (_textSpan is TextSpan)
        ? ((_textSpan as TextSpan).style ?? const TextStyle())
        : const TextStyle();

    // breakOffsets: exclusive end of each line (e.g. [12, 28, 45]).
    // Last entry should be == plainText.length (or very close to it).
    final breakOffsets = _lineBreaker(plainText, breakStyle, constraints.maxWidth);

    // 3. Derive per-line [start, end) ranges and build/update TextPainters.
    final newPainters = <TextPainter>[];
    final newStarts = <int>[];
    var cursor = 0;
    for (final end in breakOffsets) {
      final clampedEnd = end.clamp(cursor, plainText.length);
      newStarts.add(cursor);
      newPainters.add(_makePainter(_textSpan, cursor, clampedEnd));
      cursor = clampedEnd;
    }
    // If the breaker didn't cover the full text (rounding / edge cases),
    // add a final line for the remainder.
    if (cursor < plainText.length) {
      newStarts.add(cursor);
      newPainters.add(_makePainter(_textSpan, cursor, plainText.length));
    }

    _disposeLinePainters();
    _linePainters = newPainters;
    _lineStartOffsets = newStarts;

    // 4. Compute total height. Width is maxWidth (line is full-bleed like RichText).
    final totalH = lh * _linePainters.length;
    size = constraints.constrain(Size(constraints.maxWidth, totalH));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    final lh = preferredLineHeight;
    for (var i = 0; i < _linePainters.length; i++) {
      _linePainters[i].paint(context.canvas, offset + Offset(0, i * lh));
    }
  }

  @override
  bool hitTestSelf(Offset position) => true;

  @override
  void dispose() {
    _disposeLinePainters();
    _prototypePainter.dispose();
    super.dispose();
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  /// Creates and lays out a [TextPainter] for the plain-text slice [start, end)
  /// of [span], preserving rich formatting.
  ///
  /// IMPORTANT: layout() is called with NO maxWidth constraint. The line text
  /// has already been broken by Pretext; re-constraining would let Flutter run
  /// its own line breaker on the fragment, which can produce a different break
  /// (due to shaper rounding vs. TextPainter.maxIntrinsicWidth divergence) and
  /// cause lines to stack on top of each other. See pretext_article_view.dart
  /// for the full explanation.
  TextPainter _makePainter(InlineSpan span, int start, int end) {
    final sliced = _clipSpan(span, start, end);
    return TextPainter(
      text: sliced,
      textAlign: _prototypePainter.textAlign,
      textDirection: _prototypePainter.textDirection,
      textScaler: _prototypePainter.textScaler,
      strutStyle: _prototypePainter.strutStyle,
      locale: _prototypePainter.locale,
    )..layout(); // unconstrained — Pretext already decided the break point
  }

  void _disposeLinePainters() {
    for (final p in _linePainters) {
      p.dispose();
    }
  }

  /// Returns the index of the line that contains [documentOffset].
  int _lineIndexForOffset(int documentOffset) {
    // Walk backwards: the first lineStart that is <= documentOffset is our line.
    for (var i = _lineStartOffsets.length - 1; i >= 0; i--) {
      if (documentOffset >= _lineStartOffsets[i]) return i;
    }
    return 0;
  }
}

// ─── TextSpan slicer ──────────────────────────────────────────────────────────
//
// Extracts characters [start, end) from an InlineSpan tree, preserving all
// rich formatting (style, recognizer, semanticsLabel) from every ancestor span.
//
// Algorithm: depth-first walk, tracking a mutable character offset. For each
// TextSpan.text, compute the overlap of [start, end) with the span's character
// range. For WidgetSpan, preserve it whole when its offset falls in [start, end)
// (it counts as 1 character in TextPainter's offset arithmetic).

InlineSpan _clipSpan(InlineSpan root, int start, int end) {
  var offset = 0; // mutable cursor shared across the recursive walk

  InlineSpan? clip(InlineSpan span) {
    if (span is TextSpan) {
      final text = span.text ?? '';
      final spanTextStart = offset;
      final spanTextEnd = offset + text.length;

      // Clip the span's own text.
      String? clippedText;
      if (text.isNotEmpty && spanTextEnd > start && spanTextStart < end) {
        final lo = (start - spanTextStart).clamp(0, text.length);
        final hi = (end - spanTextStart).clamp(0, text.length);
        clippedText = lo < hi ? text.substring(lo, hi) : null;
      }
      offset += text.length;

      // Recurse into children.
      List<InlineSpan>? clippedChildren;
      if (span.children != null) {
        final childResults = <InlineSpan>[];
        for (final child in span.children!) {
          final clipped = clip(child);
          if (clipped != null) childResults.add(clipped);
        }
        clippedChildren = childResults.isEmpty ? null : childResults;
      }

      if (clippedText == null && clippedChildren == null) return null;
      return TextSpan(
        text: clippedText,
        style: span.style,
        children: clippedChildren,
        recognizer: span.recognizer,
        semanticsLabel: span.semanticsLabel,
      );
    }

    if (span is WidgetSpan) {
      // WidgetSpan counts as 1 character. Include it if its position is in range.
      final pos = offset;
      offset += 1;
      return (pos >= start && pos < end) ? span : null;
    }

    // Unknown span type — skip.
    return null;
  }

  return clip(root) ?? TextSpan(style: (root is TextSpan) ? root.style : null);
}
