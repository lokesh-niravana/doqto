// WhatsApp-style message formatting, parsed into a small tree the bubble
// renders (batch 4). Pure Dart — no Flutter imports — so it unit-tests fast.
//
// Blocks (one per line, paragraphs merge consecutive plain lines):
//   ```fenced code```   → [CodeBlock]
//   "- item" / "• item" → [BulletBlock]
//   "> quoted"          → [QuoteBlock]
//   anything else       → [ParagraphBlock]
// Inline (inside a block): *bold*  _italic_  ~strike~  `mono`, nested in any
// order except inside `mono`, which is literal. A marker only opens when it
// starts a word and only closes when it ends one, so "2*3*4" and
// "snake_case_name" stay as typed.
// Plain runs are then split for `@[uuid]` mentions, URLs and phone numbers.

enum InlineStyle { bold, italic, strike, mono }

sealed class InlineNode {
  final Set<InlineStyle> styles;
  const InlineNode(this.styles);
}

class TextNode extends InlineNode {
  final String text;
  const TextNode(this.text, [super.styles = const {}]);

  @override
  String toString() => 'Text($text${styles.isEmpty ? '' : ' $styles'})';
}

/// `@[<user uuid>]` — rendered as the person's name chip.
class MentionNode extends InlineNode {
  final String userId;
  const MentionNode(this.userId, [super.styles = const {}]);

  @override
  String toString() => 'Mention($userId)';
}

/// A web link as typed ([text]) and the URL to open ([href], scheme added).
class LinkNode extends InlineNode {
  final String text;
  final String href;
  const LinkNode(this.text, this.href, [super.styles = const {}]);

  @override
  String toString() => 'Link($href)';
}

/// A phone number as typed; [digits] is the dialable form.
class PhoneNode extends InlineNode {
  final String text;
  final String digits;
  const PhoneNode(this.text, this.digits, [super.styles = const {}]);

  @override
  String toString() => 'Phone($digits)';
}

sealed class RichBlock {
  const RichBlock();
}

class ParagraphBlock extends RichBlock {
  final List<InlineNode> inlines;
  const ParagraphBlock(this.inlines);
}

class BulletBlock extends RichBlock {
  final List<InlineNode> inlines;
  const BulletBlock(this.inlines);
}

class QuoteBlock extends RichBlock {
  final List<InlineNode> inlines;
  const QuoteBlock(this.inlines);
}

class CodeBlock extends RichBlock {
  final String code;
  const CodeBlock(this.code);
}

final RegExp mentionTokenPattern = RegExp(
  r'@\[([0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12})\]',
);

final RegExp _urlPattern = RegExp(
  r'''(?:https?://|www\.)[^\s<>"'`]+''',
  caseSensitive: false,
);

/// 7–15 digits with optional +, spaces, dots, dashes, parentheses.
final RegExp _phonePattern = RegExp(r'\+?\(?\d[\d\s().-]{5,18}\d');

/// Every URL in [text], in order, as openable hrefs (first one drives the
/// link preview).
List<String> extractUrls(String text) => [
      for (final m in _urlPattern.allMatches(text)) _href(_trimUrl(m.group(0)!)),
    ];

/// The ids named in [text] (`@[uuid]`), in order, without duplicates.
List<String> extractMentions(String text) {
  final out = <String>[];
  for (final m in mentionTokenPattern.allMatches(text)) {
    final id = m.group(1)!.toLowerCase();
    if (!out.contains(id)) out.add(id);
  }
  return out;
}

String _trimUrl(String raw) {
  var url = raw;
  // Trailing sentence punctuation is almost never part of the link.
  while (url.isNotEmpty && '.,;:!?)’”'.contains(url[url.length - 1])) {
    // Keep a ")" that closes one opened inside the URL (wikipedia-style).
    if (url.endsWith(')') && url.split('(').length > url.split(')').length - 1) break;
    url = url.substring(0, url.length - 1);
  }
  return url;
}

String _href(String url) =>
    url.toLowerCase().startsWith('www.') ? 'https://$url' : url;

/// Parse a whole message body into blocks.
List<RichBlock> parseRichText(String text) {
  final blocks = <RichBlock>[];
  final lines = text.split('\n');
  final paragraph = <String>[];

  void flushParagraph() {
    if (paragraph.isEmpty) return;
    blocks.add(ParagraphBlock(parseInline(paragraph.join('\n'))));
    paragraph.clear();
  }

  var i = 0;
  while (i < lines.length) {
    final line = lines[i];
    final trimmed = line.trimLeft();
    if (trimmed.startsWith('```')) {
      // Fenced block: closes at the next ``` (same line or a later one).
      final after = trimmed.substring(3);
      final sameLine = after.indexOf('```');
      if (sameLine >= 0 && after.substring(sameLine + 3).trim().isEmpty && sameLine > 0) {
        flushParagraph();
        blocks.add(CodeBlock(after.substring(0, sameLine)));
        i++;
        continue;
      }
      var j = i + 1;
      final body = <String>[if (after.isNotEmpty) after];
      var closed = false;
      while (j < lines.length) {
        final l = lines[j];
        final end = l.indexOf('```');
        if (end >= 0) {
          final head = l.substring(0, end);
          if (head.trim().isNotEmpty) body.add(head);
          closed = true;
          break;
        }
        body.add(l);
        j++;
      }
      if (closed) {
        flushParagraph();
        blocks.add(CodeBlock(body.join('\n')));
        i = j + 1;
        continue;
      }
      // Unclosed fence: literal text.
      paragraph.add(line);
      i++;
      continue;
    }
    if (trimmed.startsWith('- ') || trimmed.startsWith('• ')) {
      flushParagraph();
      blocks.add(BulletBlock(parseInline(trimmed.substring(2))));
      i++;
      continue;
    }
    if (trimmed.startsWith('> ')) {
      flushParagraph();
      blocks.add(QuoteBlock(parseInline(trimmed.substring(2))));
      i++;
      continue;
    }
    paragraph.add(line);
    i++;
  }
  flushParagraph();
  return blocks;
}

const _markers = {'*': InlineStyle.bold, '_': InlineStyle.italic, '~': InlineStyle.strike, '`': InlineStyle.mono};

bool _isWordChar(String c) => RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(c);

bool _canOpen(String s, int i) {
  // Start of text or after a non-word char; followed by a non-space.
  if (i + 1 >= s.length) return false;
  final next = s[i + 1];
  if (next.trim().isEmpty || next == s[i]) return false;
  if (i == 0) return true;
  return !_isWordChar(s[i - 1]);
}

bool _canClose(String s, int i) {
  if (i == 0) return false;
  final prev = s[i - 1];
  if (prev.trim().isEmpty || prev == s[i]) return false;
  if (i + 1 >= s.length) return true;
  return !_isWordChar(s[i + 1]);
}

/// Parse inline markers in [text] into nodes carrying [styles].
List<InlineNode> parseInline(String text, {Set<InlineStyle> styles = const {}}) {
  final out = <InlineNode>[];
  final buf = StringBuffer();

  void flush() {
    if (buf.isEmpty) return;
    out.addAll(_splitPlain(buf.toString(), styles));
    buf.clear();
  }

  var i = 0;
  while (i < text.length) {
    final c = text[i];
    final style = _markers[c];
    if (style != null && !styles.contains(style) && _canOpen(text, i)) {
      // Find the matching close on the same line.
      var j = i + 1;
      var found = -1;
      while (j < text.length && text[j] != '\n') {
        if (text[j] == c && _canClose(text, j)) {
          found = j;
          break;
        }
        j++;
      }
      if (found > i + 1) {
        flush();
        final inner = text.substring(i + 1, found);
        if (style == InlineStyle.mono) {
          out.add(TextNode(inner, {...styles, InlineStyle.mono}));
        } else {
          out.addAll(parseInline(inner, styles: {...styles, style}));
        }
        i = found + 1;
        continue;
      }
    }
    buf.write(c);
    i++;
  }
  flush();
  return out;
}

/// Split a plain run into text / mention / link / phone nodes.
List<InlineNode> _splitPlain(String text, Set<InlineStyle> styles) {
  final out = <InlineNode>[];
  final matches = <({int start, int end, InlineNode node})>[];
  for (final m in mentionTokenPattern.allMatches(text)) {
    matches.add((start: m.start, end: m.end, node: MentionNode(m.group(1)!.toLowerCase(), styles)));
  }
  for (final m in _urlPattern.allMatches(text)) {
    final url = _trimUrl(m.group(0)!);
    matches.add((start: m.start, end: m.start + url.length, node: LinkNode(url, _href(url), styles)));
  }
  for (final m in _phonePattern.allMatches(text)) {
    final raw = m.group(0)!;
    final digits = raw.replaceAll(RegExp(r'[^\d+]'), '');
    final count = digits.replaceAll('+', '').length;
    if (count < 7 || count > 15) continue;
    // Not inside a URL or mention already claimed.
    if (matches.any((x) => m.start < x.end && m.end > x.start)) continue;
    matches.add((start: m.start, end: m.end, node: PhoneNode(raw, digits, styles)));
  }
  matches.sort((a, b) => a.start.compareTo(b.start));
  var pos = 0;
  for (final m in matches) {
    if (m.start < pos) continue; // overlap (e.g. url inside mention) — skip
    if (m.start > pos) out.add(TextNode(text.substring(pos, m.start), styles));
    out.add(m.node);
    pos = m.end;
  }
  if (pos < text.length) out.add(TextNode(text.substring(pos), styles));
  return out;
}

/// Wrap the selection [start, end) of [text] in [marker] (bold → `*`). An
/// empty selection inserts a marker pair with the caret between them. Returns
/// the new text and the caret/selection to set.
({String text, int start, int end}) wrapSelection(
  String text,
  int start,
  int end,
  String marker,
) {
  final s = start.clamp(0, text.length);
  final e = end.clamp(s, text.length);
  final before = text.substring(0, s);
  final inner = text.substring(s, e);
  final after = text.substring(e);
  if (inner.isEmpty) {
    return (text: '$before$marker$marker$after', start: s + marker.length, end: s + marker.length);
  }
  // Already wrapped → unwrap.
  if (before.endsWith(marker) && after.startsWith(marker)) {
    return (
      text: before.substring(0, before.length - marker.length) + inner + after.substring(marker.length),
      start: s - marker.length,
      end: e - marker.length,
    );
  }
  return (text: '$before$marker$inner$marker$after', start: s + marker.length, end: e + marker.length);
}

/// [text] with the formatting markers removed and mention tokens replaced
/// via [nameFor] — for chat-list previews, quotes and search.
String plainText(String text, {String Function(String userId)? nameFor}) {
  final sb = StringBuffer();
  for (final b in parseRichText(text)) {
    if (sb.isNotEmpty) sb.write('\n');
    switch (b) {
      case CodeBlock(:final code):
        sb.write(code);
      case ParagraphBlock(:final inlines):
      case BulletBlock(:final inlines):
      case QuoteBlock(:final inlines):
        for (final n in inlines) {
          sb.write(switch (n) {
            TextNode(:final text) => text,
            MentionNode(:final userId) => '@${nameFor?.call(userId) ?? userId}',
            LinkNode(:final text) => text,
            PhoneNode(:final text) => text,
          });
        }
    }
  }
  return sb.toString();
}
