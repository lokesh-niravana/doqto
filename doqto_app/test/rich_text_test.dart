import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/utils/rich_text.dart';

/// The WhatsApp formatting parser (batch 4): markers, nesting, word
/// boundaries, blocks, mentions, links, phones, the toolbar helper.
void main() {
  List<InlineNode> inline(String s) =>
      (parseRichText(s).single as ParagraphBlock).inlines;

  group('inline markers', () {
    test('bold, italic, strike, mono', () {
      final n = inline('a *b* _c_ ~d~ `e` f');
      expect(n.map((x) => x.toString()).toList(), [
        'Text(a )',
        'Text(b {InlineStyle.bold})',
        'Text( )',
        'Text(c {InlineStyle.italic})',
        'Text( )',
        'Text(d {InlineStyle.strike})',
        'Text( )',
        'Text(e {InlineStyle.mono})',
        'Text( f)',
      ]);
    });

    test('nesting: bold inside italic, both styles carried', () {
      final n = inline('_see *this*_');
      expect((n[0] as TextNode).text, 'see ');
      expect(n[0].styles, {InlineStyle.italic});
      expect((n[1] as TextNode).text, 'this');
      expect(n[1].styles, {InlineStyle.italic, InlineStyle.bold});
    });

    test('mono is literal: markers inside are not parsed', () {
      final n = inline('`*not bold*`');
      expect(n.single, isA<TextNode>());
      expect((n.single as TextNode).text, '*not bold*');
      expect(n.single.styles, {InlineStyle.mono});
    });

    test('markers inside words and arithmetic stay literal', () {
      expect((inline('2*3*4').single as TextNode).text, '2*3*4');
      expect((inline('snake_case_name').single as TextNode).text, 'snake_case_name');
      expect((inline('a * b * c').single as TextNode).text, 'a * b * c');
      expect((inline('*unclosed').single as TextNode).text, '*unclosed');
      expect((inline('**').single as TextNode).text, '**');
    });

    test('a marker pair must close on the same line', () {
      final blocks = parseRichText('*a\nb*');
      final n = (blocks.single as ParagraphBlock).inlines;
      expect(n.single.styles, isEmpty);
    });
  });

  group('blocks', () {
    test('bullets, quotes, fenced code and paragraphs', () {
      final b = parseRichText('Plan:\n- *first*\n- second\n> careful\n```\nx = 1\n```\ndone');
      expect(b.length, 6);
      expect(b[0], isA<ParagraphBlock>());
      expect(b[1], isA<BulletBlock>());
      expect((b[1] as BulletBlock).inlines.first.styles, {InlineStyle.bold});
      expect(b[2], isA<BulletBlock>());
      expect(b[3], isA<QuoteBlock>());
      expect(b[4], isA<CodeBlock>());
      expect((b[4] as CodeBlock).code, 'x = 1');
      expect(b[5], isA<ParagraphBlock>());
    });

    test('one-line fence and an unclosed fence', () {
      expect((parseRichText('```inline```').single as CodeBlock).code, 'inline');
      final open = parseRichText('```oops\nstill text');
      expect(open.single, isA<ParagraphBlock>());
    });

    test('consecutive plain lines merge into one paragraph', () {
      final b = parseRichText('one\ntwo\nthree');
      expect(b.length, 1);
      expect((b.single as ParagraphBlock).inlines.single, isA<TextNode>());
      expect(((b.single as ParagraphBlock).inlines.single as TextNode).text, 'one\ntwo\nthree');
    });
  });

  group('mentions, links, phones', () {
    const uid = '7b1e2d3c-4f5a-4b6c-8d7e-9f0a1b2c3d4e';

    test('mention token becomes a MentionNode (lowercased id)', () {
      final n = inline('hi @[${uid.toUpperCase()}] ok');
      expect(n[1], isA<MentionNode>());
      expect((n[1] as MentionNode).userId, uid);
      expect(extractMentions('@[$uid] and @[$uid]'), [uid]);
    });

    test('urls become links, trailing punctuation dropped, www gets https', () {
      final n = inline('see https://example.org/a?b=1. and www.nih.gov, ok');
      final links = n.whereType<LinkNode>().toList();
      expect(links.map((l) => l.text), ['https://example.org/a?b=1', 'www.nih.gov']);
      expect(links[1].href, 'https://www.nih.gov');
      expect(extractUrls('x https://a.io/p) y'), ['https://a.io/p']);
    });

    test('phone numbers are dialable; short digit runs are not', () {
      final n = inline('call +1 (650) 555-0198 or 12345');
      final phones = n.whereType<PhoneNode>().toList();
      expect(phones.length, 1);
      expect(phones.single.digits, '+16505550198');
    });

    test('styles carry into links and mentions', () {
      final n = inline('*@[$uid] https://x.io*');
      expect(n.whereType<MentionNode>().single.styles, {InlineStyle.bold});
      expect(n.whereType<LinkNode>().single.styles, {InlineStyle.bold});
    });
  });

  group('helpers', () {
    test('wrapSelection wraps, unwraps and inserts an empty pair', () {
      expect(wrapSelection('hello world', 6, 11, '*'), (text: 'hello *world*', start: 7, end: 12));
      expect(wrapSelection('hello *world*', 7, 12, '*'), (text: 'hello world', start: 6, end: 11));
      expect(wrapSelection('ab', 1, 1, '_'), (text: 'a__b', start: 2, end: 2));
    });

    test('plainText strips markers and names mentions', () {
      const uid = '7b1e2d3c-4f5a-4b6c-8d7e-9f0a1b2c3d4e';
      expect(
        plainText('*Hi* @[$uid]\n- `x`', nameFor: (_) => 'Dr Kim'),
        'Hi @Dr Kim\nx',
      );
    });
  });
}
