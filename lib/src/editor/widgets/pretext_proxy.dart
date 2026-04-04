// ignore_for_file: dangling_library_doc_comments
/// Pretext-driven line renderer for flutter_quill_pretext.
///
/// Drop-in replacement for [RichTextProxy] + [RichText] in text_line.dart.
/// Instead of delegating line breaking to Flutter's [RenderParagraph], it
/// calls the Pretext engine directly ([prepareTextWithSegments] +
/// [layoutWithLines]) and paints each resulting line with an individually
/// laid-out [TextPainter].
///
/// ── Integration pattern ──────────────────────────────────────────────────
///
/// Wrap your [QuillEditor] with [PretextScope]:
///
///   PretextScope(
///     child: QuillEditor.basic(controller: controller),
///   )
///
/// [TextLine.build] checks for a [PretextScope] ancestor and switches to
/// [PretextRichText] when one is present.  Without a scope, [TextLine] falls
/// back to the original [RichText] path — no behavior change for existing
/// users of the package.
///
/// ── Why direct engine types instead of a function pointer ────────────────
///
/// An earlier design used a `PretextLineBreaker` function typedef.  That had
/// two problems:
///
///   1. Dart closures are never `identical()`, so the `lineBreaker != value`
///      guard in the setter always returned true, causing spurious
///      `markNeedsLayout()` calls every rebuild.
///
///   2. The function pointer prevented caching `PreparedTextWithSegments`
///      across layout passes.  Pretext's analysis + measurement phase is
///      cheap but not free; it only needs to re-run when the text or style
///      changes, not on every width-change relayout.
///
/// Using `PreparedTextWithSegments` directly solves both: the cached result is
/// compared by object identity (it's only recreated when text/style change),
/// and only the cheap `layoutWithLines()` arithmetic re-runs on resize.
///
/// ── TextSpan slicing ─────────────────────────────────────────────────────
///
/// Pretext returns [LayoutLine] objects with character-offset boundaries into
/// the paragraph's plain text.  We slice the rich [InlineSpan] tree at those
/// offsets so each line's [TextPainter] carries the correct spans (bold,
/// italic, links, etc.).  [WidgetSpan]s count as one character and are
/// preserved whole.
///
/// ── RenderContentProxyBox implementation ─────────────────────────────────
///
/// The four methods Quill's selection / caret machinery depends on:
///   • getPositionForOffset  — tap → document offset (hit-testing)
///   • getOffsetForCaret     — document offset → pixel (caret painting)
///   • getBoxesForSelection  — selection range → highlight rects
///   • getWordBoundary       — double-tap word select
///
/// Each binary-searches to the correct Pretext line and delegates to that
/// line's [TextPainter], adjusting offsets / y-coordinates as needed.

import 'dart:ui' as ui show BoxHeightStyle, BoxWidthStyle;

import 'package:flutter/rendering.dart';
import 'package:flutter/widgets.dart';
import 'package:pretext_engine/pretext_engine.dart'
    show
        InlineFlowFragmentRange,
        InlineFlowItem,
        LayoutCursor,
        PreparedInlineFlow,
        countInlineFlowLines,
        prepareInlineFlow,
        walkInlineFlowLineRanges;

import 'box.dart';

// ─── Scope ────────────────────────────────────────────────────────────────────

/// Marker [InheritedWidget] that activates Pretext line-breaking for every
/// [TextLine] in the subtree.
///
/// Place this above [QuillEditor].  [TextLine.build] calls [PretextScope.of]
/// and switches to [PretextRichText] when the scope is present.
///
/// The scope carries no configuration data — the engine derives line height
/// from the text style's [TextStyle.fontSize] via [TextPainter.preferredLineHeight].
class PretextScope extends InheritedWidget {
  const PretextScope({
    required super.child,
    super.key,
  });

  /// Returns true if a [PretextScope] is present above [context].
  static bool isActive(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<PretextScope>() != null;
  }

  /// Never notifies — the scope is stateless; presence/absence is all that
  /// matters, and that is detected by widget-tree structure, not value change.
  @override
  bool updateShouldNotify(PretextScope old) => false;
}

// ─── Widget ───────────────────────────────────────────────────────────────────

/// Replacement for [RichTextProxy] + [RichText].
///
/// Produces a [RenderPretextLine] that calls the Pretext engine to determine
/// where lines break, then paints each line with its own [TextPainter].
class PretextRichText extends LeafRenderObjectWidget {
  const PretextRichText({
    required this.textSpan,
    required this.textStyle,
    required this.textAlign,
    required this.textDirection,
    required this.strutStyle,
    required this.locale,
    required this.textScaler,
    super.key,
  });

  final InlineSpan textSpan;
  final TextStyle textStyle;
  final TextAlign textAlign;
  final TextDirection textDirection;
  final StrutStyle strutStyle;
  final Locale locale;
  final TextScaler textScaler;

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
      ..textScaler = textScaler;
  }
}

// ─── RenderObject ─────────────────────────────────────────────────────────────

/// A [RenderBox] that implements [RenderContentProxyBox] using the Pretext
/// layout engine instead of Flutter's [RenderParagraph].
///
/// Layout:
///   1. Walk the [InlineSpan] tree to produce per-span [InlineFlowItem]s.
///      Call [prepareInlineFlow] (analysis + per-item measurement).  Result
///      is cached — only re-runs when [_textSpan] or style changes, NOT on
///      every width-change relayout.
///   2. Call [walkInlineFlowLines] with the cached flow and the current
///      [constraints.maxWidth].  Produces one [InlineFlowLine] per visual
///      line.
///   3. Map each line back to plain-text offsets via [_advanceCursor], then
///      slice the rich [InlineSpan] with [_clipSpan] to build one [TextPainter]
///      per line, laid out with NO maxWidth constraint.
///   4. Report size as (maxWidth, lineHeight × lineCount).
///
/// Paint: paint each [TextPainter] at Offset(0, lineIndex × lineHeight).
///
/// Position queries: binary-search to the correct line, delegate to that
/// line's [TextPainter], adjust offsets / y-coordinates.
class RenderPretextLine extends RenderBox implements RenderContentProxyBox {
  RenderPretextLine({
    required InlineSpan textSpan,
    required TextStyle textStyle,
    required TextAlign textAlign,
    required TextDirection textDirection,
    required StrutStyle strutStyle,
    required Locale locale,
    required TextScaler textScaler,
  })  : _textSpan = textSpan,
        // Prototype painter: single space — used for textAlign/textDirection
        // propagation and the external preferredLineHeight API (cursor sizing).
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
  final TextPainter _prototypePainter;

  /// Cached result of [prepareInlineFlow].  Invalidated (set to null) when
  /// [_textSpan] or any style property changes.  Width-only relayouts reuse
  /// this and skip the analysis + measurement phase.
  PreparedInlineFlow? _preparedFlow;

  /// Flat list of styled runs extracted from [_textSpan].  Rebuilt whenever
  /// [_preparedFlow] is rebuilt.  Used to map [InlineFlowFragmentRange]
  /// item indices back to plain-text offsets.
  List<_RichItem> _richItems = [];

  /// UTF-16 offset into plainText where [_richItems[i]] starts.
  List<int> _itemStart = [];

  /// UTF-16 offset into plainText where [_richItems[i]]'s content starts —
  /// i.e. [_itemStart[i]] + the length of leading collapsible whitespace
  /// stripped by [prepareInlineFlow].
  List<int> _itemContentStart = [];

  /// One painter per Pretext line, laid out at unconstrained width.
  List<TextPainter> _linePainters = [];

  /// Character offset of the FIRST character in each line (into the span's
  /// plain text). _lineStartOffsets[i] is the start of line i.
  List<int> _lineStartOffsets = [];

  /// Total character count of the span's plain text.
  int _totalLength = 0;

  // ── Setters (each triggers relayout; text/style changes also clear cache) ──

  set textSpan(InlineSpan value) {
    if (_textSpan == value) return;
    _textSpan = value;
    _preparedFlow = null; // text changed — must re-prepare
    markNeedsLayout();
  }

  set textStyle(TextStyle value) {
    if (_prototypePainter.text!.style == value) return;
    _prototypePainter.text = TextSpan(text: ' ', style: value);
    _preparedFlow = null; // style affects measurement — must re-prepare
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
    _preparedFlow = null; // scaler affects measurement
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
    _preparedFlow = null; // locale can affect font selection and metrics
    markNeedsLayout();
  }

  // ── RenderContentProxyBox ──────────────────────────────────────────────────

  @override
  double get preferredLineHeight {
    _prototypePainter.layout();
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
    // Query only the x-coordinate — each painter is a single logical line.
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
      if (selection.end <= lineStart || selection.start >= lineEnd) continue;
      final localStart =
          (selection.start - lineStart).clamp(0, lineEnd - lineStart);
      final localEnd =
          (selection.end - lineStart).clamp(0, lineEnd - lineStart);
      if (localStart >= localEnd) continue;
      final localSel =
          TextSelection(baseOffset: localStart, extentOffset: localEnd);
      for (final box in _linePainters[i].getBoxesForSelection(
        localSel,
        boxHeightStyle: ui.BoxHeightStyle.max,
        boxWidthStyle: ui.BoxWidthStyle.tight,
      )) {
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

  /// Computes the box size without building [TextPainter]s.
  ///
  /// Flutter calls this during dry-layout passes (e.g. [IntrinsicHeight],
  /// [LayoutBuilder] probing).  The default [RenderBox] fallback would
  /// invoke the full [performLayout], creating and disposing painters that
  /// are thrown away immediately.  Here we use [countInlineFlowLines] —
  /// pure arithmetic after the cached [_preparedFlow] is available — to
  /// get the line count cheaply, avoiding all [TextPainter] allocation.
  @override
  Size computeDryLayout(BoxConstraints constraints) {
    _prototypePainter.layout(
        minWidth: constraints.minWidth, maxWidth: constraints.maxWidth);
    final lh = _prototypePainter.preferredLineHeight;

    final plainText = _textSpan.toPlainText(includeSemanticsLabels: false);
    if (plainText.isEmpty) {
      return constraints.constrain(Size(constraints.maxWidth, lh));
    }

    // Reuse the cached flow if available; build a throw-away one otherwise.
    // We do NOT cache the result here because dry layout may be called with
    // different constraints than the eventual performLayout, and overwriting
    // _preparedFlow with one prepared at the wrong scaler/style would break
    // the subsequent real layout.
    final flow = _preparedFlow ?? prepareInlineFlow(
      _extractRichItems(_textSpan)
          .map((r) => InlineFlowItem(text: r.text, style: r.style))
          .toList(),
      textScaler: _prototypePainter.textScaler,
    );

    final lineCount = countInlineFlowLines(flow, constraints.maxWidth);
    return constraints.constrain(
        Size(constraints.maxWidth, lh * (lineCount == 0 ? 1 : lineCount)));
  }

  @override
  void performLayout() {
    _prototypePainter.layout(
        minWidth: constraints.minWidth, maxWidth: constraints.maxWidth);
    final lh = _prototypePainter.preferredLineHeight;

    final plainText = _textSpan.toPlainText(includeSemanticsLabels: false);
    _totalLength = plainText.length;

    if (plainText.isEmpty) {
      _disposeLinePainters();
      _linePainters = [];
      _lineStartOffsets = [];
      size = constraints.constrain(Size(constraints.maxWidth, lh));
      return;
    }

    // Prepare InlineFlow (analysis + per-item measurement) — cached until
    // text/style/scaler changes.  Width-only relayouts skip this phase.
    if (_preparedFlow == null) {
      _richItems = _extractRichItems(_textSpan);
      var offset = 0;
      _itemStart = List<int>.filled(_richItems.length, 0);
      _itemContentStart = List<int>.filled(_richItems.length, 0);
      for (var i = 0; i < _richItems.length; i++) {
        _itemStart[i] = offset;
        final match = _leadingSpaceRe.firstMatch(_richItems[i].text);
        _itemContentStart[i] = offset + (match?.end ?? 0);
        offset += _richItems[i].text.length;
      }
      _preparedFlow = prepareInlineFlow(
        _richItems
            .map((r) => InlineFlowItem(text: r.text, style: r.style))
            .toList(),
        textScaler: _prototypePainter.textScaler,
      );
    }

    // Walk InlineFlow line ranges and build one TextPainter per line via
    // _clipSpan.  Each InlineFlowFragmentRange carries itemIndex + start/end
    // LayoutCursors; _itemContentStart[] + _cursorToUtf16() convert those
    // directly to UTF-16 offsets in plainText — no text materialisation or
    // fuzzy string matching needed.
    final newPainters = <TextPainter>[];
    final newStarts = <int>[];

    walkInlineFlowLineRanges(_preparedFlow!, constraints.maxWidth, (line) {
      if (line.fragments.isEmpty) return;
      final firstFrag = line.fragments.first;
      final lastFrag = line.fragments.last;

      final firstSegs = _preparedFlow!.segmentsForItem(firstFrag.itemIndex)!;
      final lineStart = _itemContentStart[firstFrag.itemIndex]
          + _cursorToUtf16(firstSegs, firstFrag.start);

      final lastSegs = _preparedFlow!.segmentsForItem(lastFrag.itemIndex)!;
      final lineEnd = _itemContentStart[lastFrag.itemIndex]
          + _cursorToUtf16(lastSegs, lastFrag.end);

      if (lineEnd <= lineStart) return;
      newStarts.add(lineStart);
      newPainters.add(
          _makePainter(_textSpan, lineStart, lineEnd, constraints.maxWidth));
    });

    _disposeLinePainters();
    _linePainters = newPainters;
    _lineStartOffsets = newStarts;

    final totalH = lh * (_linePainters.isEmpty ? 1 : _linePainters.length);
    size = constraints.constrain(Size(constraints.maxWidth, totalH));
  }

  @override
  void paint(PaintingContext context, Offset offset) {
    // Clip to the render box so that lines whose measured width is marginally
    // wider than constraints.maxWidth (due to kerning vs. per-segment sum
    // discrepancy between Pretext and Flutter's TextPainter) don't visually
    // overflow into adjacent content. Painters are laid out unconstrained to
    // prevent Flutter from re-breaking our pre-chosen line slices.
    final canvas = context.canvas
      ..save()
      ..clipRect(offset & size);
    final lh = preferredLineHeight;
    for (var i = 0; i < _linePainters.length; i++) {
      _linePainters[i].paint(canvas, offset + Offset(0, i * lh));
    }
    canvas.restore();
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
  /// of [span], preserving rich formatting.  Layout is unconstrained so Flutter
  /// does not re-break our pre-chosen slice; [paint()] canvas-clips to the
  /// render-box bounds for the rare case where a single word is wider than the
  /// column.
  TextPainter _makePainter(InlineSpan span, int start, int end, double maxWidth) {
    return TextPainter(
      text: _clipSpan(span, start, end),
      textAlign: _prototypePainter.textAlign,
      textDirection: _prototypePainter.textDirection,
      textScaler: _prototypePainter.textScaler,
      strutStyle: _prototypePainter.strutStyle,
      locale: _prototypePainter.locale,
    )..layout(); // unconstrained — paint() clips to box bounds
  }

  void _disposeLinePainters() {
    for (final p in _linePainters) {
      p.dispose();
    }
  }

  /// Returns the index of the line that contains [documentOffset].
  int _lineIndexForOffset(int documentOffset) {
    for (var i = _lineStartOffsets.length - 1; i >= 0; i--) {
      if (documentOffset >= _lineStartOffsets[i]) return i;
    }
    return 0;
  }
}

// ─── InlineFlow helpers ───────────────────────────────────────────────────────

class _RichItem {
  const _RichItem(this.text, this.style);
  final String text;
  final TextStyle style;
}

List<_RichItem> _extractRichItems(InlineSpan root) {
  final items = <_RichItem>[];
  void walk(InlineSpan span, TextStyle inherited) {
    if (span is TextSpan) {
      final effective = inherited.merge(span.style ?? const TextStyle());
      if ((span.text ?? '').isNotEmpty) items.add(_RichItem(span.text!, effective));
      for (final child in span.children ?? const <InlineSpan>[]) {
        walk(child, effective);
      }
    } else if (span is WidgetSpan) {
      items.add(_RichItem('\uFFFC', inherited));
    }
  }
  walk(root, const TextStyle());
  return items;
}

// ─── InlineFlow offset helpers ────────────────────────────────────────────────

// Same whitespace pattern used by prepareInlineFlow to strip item leading text.
final _leadingSpaceRe = RegExp(r'^[ \t\n\f\r]+');

// Preserved for test use via [advanceCursorForTest] — no longer called from
// production code since the walkInlineFlowLineRanges path computes offsets
// directly from [_itemContentStart] + [_cursorToUtf16].
int _advanceCursor(String plainText, int cursor, String lineText) {
  var pi = cursor;
  var li = 0;
  while (li < lineText.length && pi < plainText.length) {
    if (lineText[li] == plainText[pi]) {
      li++;
      pi++;
    } else {
      pi++;
    }
  }
  return pi;
}

/// Converts a [LayoutCursor] within [segments] to a UTF-16 code-unit offset.
///
/// [cursor.segmentIndex] selects the segment; [cursor.graphemeIndex] counts
/// Unicode code points (runes) into that segment — NOT UTF-16 code units.
/// This function accumulates full segment lengths (in UTF-16) for segments
/// before [cursor.segmentIndex], then walks runes for the partial segment.
int _cursorToUtf16(List<String> segments, LayoutCursor cursor) {
  var offset = 0;
  for (var si = 0; si < cursor.segmentIndex && si < segments.length; si++) {
    offset += segments[si].length;
  }
  if (cursor.segmentIndex < segments.length) {
    final seg = segments[cursor.segmentIndex];
    var gi = 0;
    for (final rune in seg.runes) {
      if (gi >= cursor.graphemeIndex) break;
      offset += rune > 0xFFFF ? 2 : 1;
      gi++;
    }
  }
  return offset;
}

// ─── TextSpan slicer ──────────────────────────────────────────────────────────
//
// Extracts characters [start, end) from an InlineSpan tree, preserving all
// rich formatting (style, recognizer, semanticsLabel) from every ancestor span.
//
// Algorithm: depth-first walk, tracking a mutable character cursor. For each
// TextSpan.text, compute the overlap with [start, end). For WidgetSpan, include
// it whole when its offset falls within the range (it counts as 1 character in
// TextPainter's offset arithmetic).

InlineSpan _clipSpan(InlineSpan root, int start, int end) {
  var cursor = 0; // mutable offset shared across the recursive walk

  InlineSpan? clip(InlineSpan span) {
    if (span is TextSpan) {
      final text = span.text ?? '';
      final spanStart = cursor;
      final spanEnd = cursor + text.length;

      String? clippedText;
      if (text.isNotEmpty && spanEnd > start && spanStart < end) {
        final lo = (start - spanStart).clamp(0, text.length);
        final hi = (end - spanStart).clamp(0, text.length);
        clippedText = lo < hi ? text.substring(lo, hi) : null;
      }
      cursor += text.length;

      List<InlineSpan>? clippedChildren;
      if (span.children != null) {
        final results = <InlineSpan>[];
        for (final child in span.children!) {
          final c = clip(child);
          if (c != null) results.add(c);
        }
        clippedChildren = results.isEmpty ? null : results;
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
      final pos = cursor;
      cursor += 1;
      return (pos >= start && pos < end) ? span : null;
    }

    return null; // unknown span type — skip
  }

  return clip(root) ?? TextSpan(style: (root is TextSpan) ? root.style : null);
}

// ─── Test-visible wrappers ────────────────────────────────────────────────────
//
// _clipSpan and _advanceCursor are package-private top-level functions.
// These thin wrappers expose them under stable names for unit tests so tests
// can import this file directly without relying on name-mangling hacks.

/// Test-only alias for [_clipSpan]. Do not call from production code.
@visibleForTesting
InlineSpan clipSpanForTest(InlineSpan root, int start, int end) =>
    _clipSpan(root, start, end);

/// Test-only alias for [_advanceCursor]. Do not call from production code.
@visibleForTesting
int advanceCursorForTest(String plainText, int cursor, String lineText) =>
    _advanceCursor(plainText, cursor, lineText);
