import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/radii.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../core/utils/rich_text.dart';

/// A message body with WhatsApp-style formatting, @mention chips, tappable
/// links / phone numbers and an optional search [highlight] (batch 4).
class MessageText extends StatefulWidget {
  final String text;
  final TextStyle style;
  final bool isMine;

  /// Name for a mentioned user id; null → the id stays as "@someone".
  final String? Function(String userId)? nameFor;
  final ValueChanged<String>? onMentionTap;
  final ValueChanged<String>? onLinkTap;
  final ValueChanged<String>? onPhoneTap;

  /// Case-insensitive query to mark (in-chat search).
  final String? highlight;

  const MessageText({
    super.key,
    required this.text,
    required this.style,
    required this.isMine,
    this.nameFor,
    this.onMentionTap,
    this.onLinkTap,
    this.onPhoneTap,
    this.highlight,
  });

  @override
  State<MessageText> createState() => _MessageTextState();
}

class _MessageTextState extends State<MessageText> {
  final _recognizers = <GestureRecognizer>[];

  @override
  void dispose() {
    for (final r in _recognizers) {
      r.dispose();
    }
    super.dispose();
  }

  TapGestureRecognizer _tap(VoidCallback onTap) {
    final r = TapGestureRecognizer()..onTap = onTap;
    _recognizers.add(r);
    return r;
  }

  @override
  Widget build(BuildContext context) {
    for (final r in _recognizers) {
      r.dispose();
    }
    _recognizers.clear();
    final blocks = parseRichText(widget.text);
    if (blocks.length == 1 && blocks.first is ParagraphBlock) {
      return _inline((blocks.first as ParagraphBlock).inlines);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final b in blocks)
          switch (b) {
            ParagraphBlock(:final inlines) => _inline(inlines),
            BulletBlock(:final inlines) => Padding(
                padding: const EdgeInsets.only(left: AppSpacing.xs),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('•  ', style: widget.style),
                    Flexible(child: _inline(inlines)),
                  ],
                ),
              ),
            QuoteBlock(:final inlines) => Container(
                key: const ValueKey('rich-quote'),
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.only(left: AppSpacing.sm),
                decoration: BoxDecoration(
                  border: Border(
                    left: BorderSide(
                      color: widget.isMine
                          ? AppColors.white.withValues(alpha: 0.6)
                          : AppColors.medBlue,
                      width: 3,
                    ),
                  ),
                ),
                child: _inline(inlines, italic: true),
              ),
            CodeBlock(:final code) => Container(
                key: const ValueKey('rich-code'),
                width: double.infinity,
                margin: const EdgeInsets.symmetric(vertical: 2),
                padding: const EdgeInsets.all(AppSpacing.sm),
                decoration: BoxDecoration(
                  color: widget.isMine
                      ? AppColors.white.withValues(alpha: 0.15)
                      : AppColors.gray100,
                  borderRadius: AppRadii.rSm,
                ),
                child: Text(
                  code,
                  style: widget.style.copyWith(fontFamily: 'Menlo', fontFamilyFallback: const ['monospace']),
                ),
              ),
          },
      ],
    );
  }

  Widget _inline(List<InlineNode> nodes, {bool italic = false}) {
    final base = italic ? widget.style.copyWith(fontStyle: FontStyle.italic) : widget.style;
    return Text.rich(TextSpan(children: [for (final n in nodes) ..._span(n, base)]));
  }

  TextStyle _styled(TextStyle base, Set<InlineStyle> styles) {
    var s = base;
    if (styles.contains(InlineStyle.bold)) s = s.copyWith(fontWeight: FontWeight.w700);
    if (styles.contains(InlineStyle.italic)) s = s.copyWith(fontStyle: FontStyle.italic);
    if (styles.contains(InlineStyle.strike)) {
      s = s.copyWith(decoration: TextDecoration.lineThrough, decorationColor: s.color);
    }
    if (styles.contains(InlineStyle.mono)) {
      s = s.copyWith(fontFamily: 'Menlo', fontFamilyFallback: const ['monospace']);
    }
    return s;
  }

  Color get _accent => widget.isMine ? AppColors.white : AppColors.medBlue;

  List<InlineSpan> _span(InlineNode n, TextStyle base) {
    final st = _styled(base, n.styles);
    switch (n) {
      case TextNode(:final text):
        return _highlighted(text, st);
      case MentionNode(:final userId):
        final name = widget.nameFor?.call(userId);
        return [
          TextSpan(
            text: '@${name ?? 'someone'}',
            style: st.copyWith(
              color: _accent,
              fontWeight: FontWeight.w700,
              backgroundColor: widget.isMine
                  ? AppColors.white.withValues(alpha: 0.18)
                  : AppColors.medBlueLight,
            ),
            recognizer: widget.onMentionTap == null ? null : _tap(() => widget.onMentionTap!(userId)),
            semanticsLabel: 'mention ${name ?? ''}',
          ),
        ];
      case LinkNode(:final text, :final href):
        return [
          TextSpan(
            text: text,
            style: st.copyWith(
              color: _accent,
              decoration: TextDecoration.underline,
              decorationColor: _accent,
            ),
            recognizer: widget.onLinkTap == null ? null : _tap(() => widget.onLinkTap!(href)),
          ),
        ];
      case PhoneNode(:final text, :final digits):
        return [
          TextSpan(
            text: text,
            style: st.copyWith(
              color: _accent,
              decoration: TextDecoration.underline,
              decorationColor: _accent,
            ),
            recognizer: widget.onPhoneTap == null ? null : _tap(() => widget.onPhoneTap!(digits)),
          ),
        ];
    }
  }

  /// Split [text] around the search query, marking the matches.
  List<InlineSpan> _highlighted(String text, TextStyle st) {
    final q = widget.highlight?.trim().toLowerCase();
    if (q == null || q.isEmpty) return [TextSpan(text: text, style: st)];
    final lower = text.toLowerCase();
    final out = <InlineSpan>[];
    var pos = 0;
    while (true) {
      final i = lower.indexOf(q, pos);
      if (i < 0) break;
      if (i > pos) out.add(TextSpan(text: text.substring(pos, i), style: st));
      out.add(TextSpan(
        text: text.substring(i, i + q.length),
        style: st.copyWith(
          backgroundColor: AppColors.amber.withValues(alpha: 0.55),
          color: AppColors.gray900,
          fontWeight: FontWeight.w600,
        ),
      ));
      pos = i + q.length;
    }
    if (pos < text.length) out.add(TextSpan(text: text.substring(pos), style: st));
    return out;
  }
}

/// Default body style for a bubble side — kept here so previews, quotes and
/// the bubble agree.
TextStyle messageBodyStyle({required bool isMine}) =>
    AppText.messageBody.copyWith(color: isMine ? AppColors.white : AppColors.textPrimary);
