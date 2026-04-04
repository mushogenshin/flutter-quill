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
    show PreparedTextWithSegments, layoutWithLines, prepareTextWithSegments;

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
///   1. Call [prepareTextWithSegments] (analysis + measurement).  Result is
///      cached by object identity — only re-runs when [_textSpan] or style
///      changes, NOT on every width-change relayout.
///   2. Call [layoutWithLines] with the cached prepared data and the current
///      [constraints.maxWidth].  Pure arithmetic — fast on every resize.
///   3. Slice the rich [InlineSpan] at each [LayoutLine] boundary and build
///      one [TextPainter] per line, laid out with NO maxWidth constraint.
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
        // Prototype painter: measures a single space to derive preferredLineHeight
        // without running a full layout — same technique as RenderParagraphProxy.
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

  /// Cached result of [prepareTextWithSegments].  Invalidated (set to null)
  /// when [_textSpan] or any style property changes.  Only the cheap
  /// [layoutWithLines] arithmetic re-runs on width-only changes.
  PreparedTextWithSegments? _prepared;

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
    _prepared = null; // text changed — must re-prepare
    markNeedsLayout();
  }

  set textStyle(TextStyle value) {
    if (_prototypePainter.text!.style == value) return;
    _prototypePainter.text = TextSpan(text: ' ', style: value);
    _prepared = null; // style affects measurement — must re-prepare
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
    _prepared = null; // scaler affects measurement
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
    _prepared = null; // locale can affect font selection and metrics
    markNeedsLayout();
  }

  // ── RenderContentProxyBox ──────────────────────────────────────────────────

  @override
  double get preferredLineHeight {
    // The prototype painter is always kept in sync with the current style.
    // We must call layout() here because preferredLineHeight is queried before
    // performLayout (e.g. for block sizing hints).
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

  @override
  void performLayout() {
    // 1. Layout prototype to get the authoritative line height.
    _prototypePainter.layout(
        minWidth: constraints.minWidth, maxWidth: constraints.maxWidth);
    final lh = _prototypePainter.preferredLineHeight;

    // 2. Extract plain text.
    final plainText = _textSpan.toPlainText(includeSemanticsLabels: false);
    _totalLength = plainText.length;

    if (plainText.isEmpty) {
      _disposeLinePainters();
      _linePainters = [];
      _lineStartOffsets = [];
      size = constraints.constrain(Size(constraints.maxWidth, lh));
      return;
    }

    // 3. Prepare text (analysis + measurement) — cached until text/style changes.
    //    Only the pure-arithmetic layoutWithLines() re-runs on width changes.
    final style = (_textSpan is TextSpan)
        ? ((_textSpan as TextSpan).style ?? const TextStyle())
        : const TextStyle();
    _prepared ??= prepareTextWithSegments(plainText, style);

    // 4. Run the Pretext line-breaking algorithm for the current column width.
    final result = layoutWithLines(_prepared!, constraints.maxWidth, lh);

    // 5. Build one TextPainter per Pretext line by slicing the rich InlineSpan.
    //
    // CURSOR DRIFT FIX: line.text is built from Pretext's *normalised* text
    // (whitespace collapsed, trailing \n stripped), but plainText is the raw
    // toPlainText() output which may be longer.  Using line.text.length to
    // advance through plainText causes cumulative drift that manifests as
    // mid-word splits (e.g. "connec" + "t").
    //
    // Instead we use _advanceCursor(), which walks plainText character-by-
    // character matching against line.text and skips chars that were removed
    // by normalisation (extra spaces, collapsed \n, etc.).
    final newPainters = <TextPainter>[];
    final newStarts = <int>[];
    var cursor = 0;
    for (final line in result.lines) {
      newStarts.add(cursor);
      final end = _advanceCursor(plainText, cursor, line.text);
      newPainters.add(_makePainter(_textSpan, cursor, end, constraints.maxWidth));
      cursor = end;
    }
    // Safety: consume any remaining plainText not covered by Pretext lines
    // (typically the trailing \n that normalisation strips from Quill paragraphs).
    // Skip whitespace-only remainders — they are normalisation artifacts and
    // should not produce an extra visible line.
    if (cursor < plainText.length) {
      final remainder = plainText.substring(cursor);
      if (remainder.trim().isNotEmpty) {
        newStarts.add(cursor);
        newPainters.add(_makePainter(_textSpan, cursor, plainText.length, constraints.maxWidth));
      }
    }

    _disposeLinePainters();
    _linePainters = newPainters;
    _lineStartOffsets = newStarts;

    final totalH = lh * _linePainters.length;
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
  /// of [span], preserving rich formatting.
  ///
  /// IMPORTANT: layout() is called with NO maxWidth constraint. The line text
  /// has already been broken by Pretext. Constraining to maxWidth would cause
  /// Flutter to re-break our pre-chosen slices whenever its full-line kerning
  /// measurement disagrees with Pretext's per-segment sum — the re-broken
  /// content then overlaps with the next painter and appears to "disappear".
  ///
  /// Instead, we paint unconstrained slices and clip the canvas to the render
  /// box bounds in paint(). Lines that are marginally too wide (typically ≤2px
  /// due to kerning) get clipped at the right edge rather than re-wrapped.
  TextPainter _makePainter(InlineSpan span, int start, int end, double maxWidth) {
    return TextPainter(
      text: _clipSpan(span, start, end),
      textAlign: _prototypePainter.textAlign,
      textDirection: _prototypePainter.textDirection,
      textScaler: _prototypePainter.textScaler,
      strutStyle: _prototypePainter.strutStyle,
      locale: _prototypePainter.locale,
    )..layout(); // unconstrained — see comment above; paint() clips to box bounds
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

// ─── Cursor advance (normalisation-aware) ─────────────────────────────────────
//
// Pretext normalises the text before analysis (collapses whitespace runs,
// strips a leading/trailing space, converts \n to space in non-preWrap mode).
// This means line.text is shorter than the corresponding slice of plainText
// whenever normalisation removes characters.  Using line.text.length to
// advance through plainText causes cumulative drift and wrong per-line slicing.
//
// Solution: walk plainText from [cursor] character-by-character, matching
// against lineText.  When a plainText char is absent from lineText it was
// normalised away — skip it in plainText only.  Return the new plainText
// position after consuming all of lineText.

int _advanceCursor(String plainText, int cursor, String lineText) {
  var pi = cursor; // index into plainText
  var li = 0;      // index into lineText
  while (li < lineText.length && pi < plainText.length) {
    if (lineText[li] == plainText[pi]) {
      li++;
      pi++;
    } else {
      // plainText has a character that was collapsed/stripped by normalisation
      // (e.g. an extra space, a \n turned into a space that then got trimmed).
      // Skip it in plainText; do NOT advance li.
      pi++;
    }
  }
  return pi;
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
