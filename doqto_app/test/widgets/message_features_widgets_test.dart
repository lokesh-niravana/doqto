import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/constants/strings.dart';
import 'package:doqto_app/core/enums/app_enums.dart';
import 'package:doqto_app/data/models/group.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/services/url_opener.dart';
import 'package:doqto_app/ui/widgets/external_link_confirm.dart';
import 'package:doqto_app/ui/widgets/link_preview_card.dart';
import 'package:doqto_app/ui/widgets/mention_autocomplete.dart';
import 'package:doqto_app/ui/widgets/mention_controller.dart';
import 'package:doqto_app/ui/widgets/message_context_menu.dart';
import 'package:doqto_app/ui/widgets/message_text.dart';
import 'package:doqto_app/ui/widgets/pinned_banner.dart';
import 'package:doqto_app/ui/widgets/quote_strip.dart';
import 'package:doqto_app/ui/widgets/report_message_sheet.dart';
import 'package:doqto_app/ui/widgets/swipe_to_reply.dart';
import 'package:doqto_app/ui/widgets/unread_divider.dart';

/// The batch 4 building blocks in isolation: context menu, quote strip,
/// swipe-to-reply, pinned banner, link preview, report sheet (incl. the
/// keyboard rule), mentions, rich message text, unread divider, the
/// external-link confirm.
const _uid = '7b1e2d3c-4f5a-4b6c-8d7e-9f0a1b2c3d4e';

Message _msg({String content = 'hello', String type = 'text', String? deletedAt}) => Message.fromJson({
      'id': 'm1',
      'conversation_id': 'c1',
      'sender_id': 'u2',
      'type': type,
      'content': content,
      'created_at': '2026-11-08T10:00:00Z',
      'seq': 1,
      'deleted_at': deletedAt,
    });

Widget _app(Widget child) => ProviderScope(
      child: MaterialApp(home: Scaffold(body: Center(child: child))),
    );

/// A screen with one button that opens [open]; the result lands in [out].
Widget _opener<T>(Future<T?> Function(BuildContext) open, List<T?> out) => _app(
      Builder(
        builder: (ctx) => ElevatedButton(
          key: const ValueKey('open'),
          onPressed: () async => out.add(await open(ctx)),
          child: const Text('open'),
        ),
      ),
    );

void main() {
  group('context menu', () {
    testWidgets('tray on top, one row per action, a row resolves to its action', (tester) async {
      final out = <ContextMenuResult?>[];
      await tester.pumpWidget(_opener(
        (ctx) => showMessageContextMenu(ctx,
            actions: const [MessageAction.reply, MessageAction.forward, MessageAction.copy, MessageAction.delete],
            reactable: true),
        out,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('message-context-menu')), findsOneWidget);
      expect(find.byKey(const ValueKey('reaction-tray')), findsOneWidget);
      for (final a in [MessageAction.reply, MessageAction.forward, MessageAction.copy, MessageAction.delete]) {
        expect(find.byKey(ValueKey('ctx-${a.name}')), findsOneWidget);
        expect(find.text(a.label), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('ctx-star')), findsNothing, reason: 'only the actions asked for');
      await tester.tap(find.byKey(const ValueKey('ctx-forward')));
      await tester.pumpAndSettle();
      expect(out.single, isA<ContextMenuAction>().having((r) => r.action, 'action', MessageAction.forward));
      expect(find.byKey(const ValueKey('message-context-menu')), findsNothing);
    });

    testWidgets('a tray emoji resolves to a reaction; "+" to a null emoji; no tray when not reactable',
        (tester) async {
      final out = <ContextMenuResult?>[];
      await tester.pumpWidget(_opener(
        (ctx) => showMessageContextMenu(ctx, actions: const [MessageAction.copy], reactable: true),
        out,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reaction-pick-👍')));
      await tester.pumpAndSettle();
      expect(out.single, isA<ContextMenuReaction>().having((r) => r.emoji, 'emoji', '👍'));

      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('reaction-more')));
      await tester.pumpAndSettle();
      expect(out.last, isA<ContextMenuReaction>().having((r) => r.emoji, 'emoji', isNull));

      final out2 = <ContextMenuResult?>[];
      await tester.pumpWidget(_opener(
        (ctx) => showMessageContextMenu(ctx, actions: const [MessageAction.info], reactable: false),
        out2,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('reaction-tray')), findsNothing);
      expect(find.byKey(const ValueKey('ctx-info')), findsOneWidget);
    });

    test('labels and destructive flags', () {
      expect(MessageAction.reply.label, Strings.chatReply);
      expect(MessageAction.unstar.label, Strings.chatUnstar);
      expect(MessageAction.unpin.label, Strings.chatUnpinMessage);
      expect(MessageAction.delete.destructive, isTrue);
      expect(MessageAction.report.destructive, isTrue);
      expect(MessageAction.copy.destructive, isFalse);
    });
  });

  group('quote strip', () {
    testWidgets('shows the sender and a plain-text preview; close fires', (tester) async {
      var closed = 0;
      var tapped = 0;
      await tester.pumpWidget(_app(QuoteStrip(
        quote: ReplyPreview(id: 'm0', senderId: 'u2', type: MessageType.text, preview: '*Bold* note @[$_uid]'),
        senderName: 'Dr Kim',
        isMine: false,
        nameFor: (_) => 'Dr Lee',
        onTap: () => tapped++,
        onClose: () => closed++,
      )));
      expect(find.byKey(const ValueKey('quote-strip')), findsOneWidget);
      expect(find.text('Dr Kim'), findsOneWidget);
      expect(find.text('Bold note @Dr Lee'), findsOneWidget, reason: 'markers stripped, mention named');
      await tester.tap(find.byKey(const ValueKey('quote-close')));
      expect(closed, 1);
      await tester.tap(find.text('Dr Kim'));
      expect(tapped, 1);
    });

    testWidgets('a media quote shows its kind; no close button in a bubble', (tester) async {
      await tester.pumpWidget(_app(const QuoteStrip(
        quote: ReplyPreview(id: 'm0', senderId: 'u2', type: MessageType.image, preview: 'Photo'),
        senderName: 'You',
        isMine: true,
      )));
      expect(find.text('Photo'), findsOneWidget);
      expect(find.byKey(const ValueKey('quote-close')), findsNothing);
    });
  });

  group('swipe to reply', () {
    Widget host({bool enabled = true, VoidCallback? onReply}) => _app(SizedBox(
          width: 300,
          child: SwipeToReply(
            enabled: enabled,
            onReply: onReply,
            child: Container(height: 60, color: Colors.transparent, child: const Text('row')),
          ),
        ));

    testWidgets('a drag past the threshold fires once; a short one does not', (tester) async {
      var fired = 0;
      await tester.pumpWidget(host(onReply: () => fired++));
      final g = await tester.startGesture(tester.getCenter(find.text('row')));
      await g.moveBy(const Offset(30, 0));
      await tester.pump();
      expect(find.byKey(const ValueKey('swipe-reply-icon')), findsOneWidget, reason: 'icon appears as you drag');
      await g.up();
      await tester.pumpAndSettle();
      expect(fired, 0, reason: '30 px is under the 48 px threshold');

      await tester.drag(find.text('row'), const Offset(SwipeToReply.maxDrag + 40, 0));
      await tester.pumpAndSettle();
      expect(fired, 1);
      expect(find.byKey(const ValueKey('swipe-reply-icon')), findsNothing, reason: 'springs back');
    });

    testWidgets('disabled or without a handler: plain child, no gesture', (tester) async {
      await tester.pumpWidget(host(enabled: false, onReply: () {}));
      await tester.drag(find.text('row'), const Offset(100, 0));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('swipe-reply-icon')), findsNothing);
    });
  });

  group('pinned banner', () {
    testWidgets('preview, sender, tap and unpin', (tester) async {
      var taps = 0;
      var unpins = 0;
      await tester.pumpWidget(_app(PinnedBanner(
        message: _msg(content: '_Rounds_ at 7 @[$_uid]'),
        senderName: 'Dr Kim',
        nameFor: (_) => 'Dr Lee',
        onTap: () => taps++,
        onUnpin: () => unpins++,
      )));
      expect(find.byKey(const ValueKey('pinned-banner')), findsOneWidget);
      expect(find.text('${Strings.chatPinnedMessage} · Dr Kim'), findsOneWidget);
      expect(find.text('Rounds at 7 @Dr Lee'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('pinned-banner-text')));
      expect(taps, 1);
      await tester.tap(find.byKey(const ValueKey('pinned-banner-unpin')));
      expect(unpins, 1);
    });

    testWidgets('a pin whose message is not loaded yet still shows; no unpin for non-admins', (tester) async {
      await tester.pumpWidget(_app(PinnedBanner(message: null, senderName: null, onTap: () {})));
      expect(find.text(Strings.chatPinnedMessage), findsNWidgets(2));
      expect(find.byKey(const ValueKey('pinned-banner-unpin')), findsNothing);
      await tester.pumpWidget(_app(PinnedBanner(message: _msg(type: 'image'), senderName: 'Dr Kim', onTap: () {})));
      expect(find.text('Photo'), findsOneWidget);
    });
  });

  group('link preview', () {
    testWidgets('title, description, host fallback, close', (tester) async {
      var closed = 0;
      // Inside a column with no height bound, like a bubble or the composer.
      await tester.pumpWidget(_app(SizedBox(
        width: 260,
        child: ListView(shrinkWrap: true, children: [
          LinkPreviewView(
          preview: const LinkPreview(
            url: 'https://www.nejm.org/doi/full/10.1056/x',
            title: 'Trial results',
            description: 'A randomized trial.',
          ),
          isMine: false,
          onClose: () => closed++,
        ),
        ]),
      )));
      expect(tester.takeException(), isNull);
      expect(find.byKey(const ValueKey('link-preview')), findsOneWidget);
      expect(find.text('Trial results'), findsOneWidget);
      expect(find.text('A randomized trial.'), findsOneWidget);
      expect(find.text('nejm.org'), findsOneWidget, reason: 'host without www when no site name');
      await tester.tap(find.byKey(const ValueKey('link-preview-close')));
      expect(closed, 1);
    });

    testWidgets('site name wins over host; no close button in a bubble; image decodes', (tester) async {
      // 1x1 transparent PNG.
      const png =
          'data:image/png;base64,iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNkYPhfDwAChwGA60e6kgAAAABJRU5ErkJggg==';
      await tester.pumpWidget(_app(const SizedBox(
        width: 260,
        child: LinkPreviewView(
          preview: LinkPreview(url: 'https://a.io/x', title: 'T', siteName: 'Site A', imageDataUrl: png),
          isMine: true,
        ),
      )));
      expect(find.text('Site A'), findsOneWidget);
      expect(find.text('a.io'), findsNothing);
      expect(find.byKey(const ValueKey('link-preview-close')), findsNothing);
      expect(find.byType(Image), findsOneWidget);
      expect(LinkPreviewView.decodeDataUrl(png), isNotNull);
      expect(LinkPreviewView.decodeDataUrl('https://not-data'), isNull);
      expect(LinkPreviewView.decodeDataUrl('data:image/png;base64,***'), isNull);
      expect(LinkPreviewView.decodeDataUrl(null), isNull);
    });
  });

  group('report sheet', () {
    testWidgets('submit needs a reason; details optional; returns the report', (tester) async {
      final out = <MessageReport?>[];
      await tester.pumpWidget(_opener(showReportMessageSheet, out));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('report-sheet')), findsOneWidget);
      for (final r in ReportReason.values) {
        expect(find.byKey(ValueKey('report-reason-${r.wire}')), findsOneWidget);
      }
      final submit = find.byKey(const ValueKey('report-submit'));
      await tester.tap(submit, warnIfMissed: false);
      await tester.pumpAndSettle();
      expect(out, isEmpty, reason: 'disabled until a reason is picked');

      await tester.tap(find.byKey(const ValueKey('report-reason-phi_misuse')));
      await tester.pumpAndSettle();
      await tester.enterText(
          find.descendant(of: find.byKey(const ValueKey('report-details')), matching: find.byType(TextField)),
          '  Shared a patient MRN.  ');
      await tester.pumpAndSettle();
      await tester.ensureVisible(submit);
      await tester.tap(submit);
      await tester.pumpAndSettle();
      expect(out.single!.reason, ReportReason.phiMisuse);
      expect(out.single!.details, 'Shared a patient MRN.');
      expect(find.byKey(const ValueKey('report-sheet')), findsNothing);
    });

    testWidgets('details field: tap outside dismisses the keyboard (CLAUDE.md rule)', (tester) async {
      final out = <MessageReport?>[];
      await tester.pumpWidget(_opener(showReportMessageSheet, out));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      final field = find.descendant(of: find.byKey(const ValueKey('report-details')), matching: find.byType(TextField));
      await tester.tap(field);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      await tester.tap(find.text(Strings.chatReportTitle));
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
    });

    test('reason labels are human', () {
      for (final r in ReportReason.values) {
        expect(reportReasonLabel(r), isNot(contains('_')));
        expect(reportReasonLabel(r), isNotEmpty);
      }
    });
  });

  group('mentions', () {
    test('controller: active query, insert → chip, wire form, restore from wire', () {
      final c = MentionController();
      c.value = const TextEditingValue(text: 'hey @ki', selection: TextSelection.collapsed(offset: 7));
      expect(c.activeMention(), (query: 'ki', start: 4));
      c.insertMention(userId: _uid, name: 'Dr Kim');
      expect(c.text, 'hey @Dr Kim ');
      expect(c.selection.baseOffset, c.text.length);
      expect(c.activeMention(), isNull, reason: 'a completed chip is not a query');
      expect(c.wireText, 'hey @[$_uid] ');
      expect(c.mentionedIds, [_uid]);

      // Email-ish text and newlines are not mentions.
      c.value = const TextEditingValue(text: 'mail a@b', selection: TextSelection.collapsed(offset: 8));
      expect(c.activeMention(), isNull);
      c.value = const TextEditingValue(text: '@a\nb', selection: TextSelection.collapsed(offset: 4));
      expect(c.activeMention(), isNull);
      c.value = const TextEditingValue(text: 'hi @', selection: TextSelection.collapsed(offset: 4));
      expect(c.activeMention(), (query: '', start: 3));

      // Draft restore: tokens come back as chips, unknown ids keep the token.
      final d = MentionController();
      d.setFromWire('ping @[$_uid] and @[00000000-0000-4000-8000-000000000000]', (id) => id == _uid ? 'Dr Kim' : null);
      expect(d.text, 'ping @Dr Kim and @[00000000-0000-4000-8000-000000000000]');
      expect(d.wireText, 'ping @[$_uid] and @[00000000-0000-4000-8000-000000000000]');
      // A chip removed by the user leaves no stale token.
      d.text = 'ping and';
      expect(d.wireText, 'ping and');
      expect(d.mentionedIds, isEmpty);
    });

    testWidgets('autocomplete filters by name, excludes me, caps at 6, picks', (tester) async {
      GroupMember member(String id, String name) => GroupMember(
            userId: id,
            fullName: name,
            specialty: null,
            headline: null,
            avatarColor: null,
            avatarUrl: null,
            role: GroupRole.member,
            state: GroupMemberState.active,
          );
      final members = [
        member('me', 'Dr Me'),
        member('k1', 'Dr Kim'),
        member('l1', 'Dr Lee'),
        for (var i = 0; i < 8; i++) member('x$i', 'Dr Xavier $i'),
      ];
      GroupMember? picked;
      await tester.pumpWidget(_app(MentionAutocomplete(members: members, query: 'k', meId: 'me', onPick: (m) => picked = m)));
      expect(find.byKey(const ValueKey('mention-k1')), findsOneWidget);
      expect(find.byKey(const ValueKey('mention-l1')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('mention-k1')));
      expect(picked?.userId, 'k1');

      await tester.pumpWidget(_app(MentionAutocomplete(members: members, query: '', meId: 'me', onPick: (_) {})));
      expect(find.byKey(const ValueKey('mention-me')), findsNothing, reason: 'never suggest myself');
      expect(find.byType(ListTile), findsNWidgets(6));

      await tester.pumpWidget(_app(MentionAutocomplete(members: members, query: 'zzz', meId: 'me', onPick: (_) {})));
      expect(find.byKey(const ValueKey('mention-autocomplete')), findsNothing, reason: 'nothing to show, no box');
    });
  });

  group('message text', () {
    RichText rich(WidgetTester t) => t.widget<RichText>(find.byType(RichText).first);
    List<TextSpan> spans(WidgetTester t) {
      final out = <TextSpan>[];
      (rich(t).text as TextSpan).visitChildren((s) {
        if (s is TextSpan && s.text != null) out.add(s);
        return true;
      });
      return out;
    }

    testWidgets('formatting becomes styled spans', (tester) async {
      await tester.pumpWidget(_app(MessageText(text: 'a *b* _c_ ~d~ `e`', style: messageBodyStyle(isMine: false), isMine: false)));
      final s = spans(tester);
      expect(s.firstWhere((x) => x.text == 'b').style!.fontWeight, FontWeight.w700);
      expect(s.firstWhere((x) => x.text == 'c').style!.fontStyle, FontStyle.italic);
      expect(s.firstWhere((x) => x.text == 'd').style!.decoration, TextDecoration.lineThrough);
      expect(s.firstWhere((x) => x.text == 'e').style!.fontFamily, 'Menlo');
      expect(find.text('a b c d e', findRichText: true), findsOneWidget, reason: 'markers are not shown');
    });

    testWidgets('mention chip shows the name and taps through; links and phones tap through', (tester) async {
      String? mention, link, phone;
      await tester.pumpWidget(_app(MessageText(
        text: 'cc @[$_uid] see https://nih.gov/x or call +1 650-555-0198',
        style: messageBodyStyle(isMine: false),
        isMine: false,
        nameFor: (id) => id == _uid ? 'Dr Kim' : null,
        onMentionTap: (id) => mention = id,
        onLinkTap: (h) => link = h,
        onPhoneTap: (d) => phone = d,
      )));
      final s = spans(tester);
      final chip = s.firstWhere((x) => x.text == '@Dr Kim');
      expect(chip.style!.fontWeight, FontWeight.w700);
      expect(chip.style!.backgroundColor, isNotNull);
      (chip.recognizer as TapGestureRecognizer).onTap!();
      expect(mention, _uid);
      final l = s.firstWhere((x) => x.text == 'https://nih.gov/x');
      expect(l.style!.decoration, TextDecoration.underline);
      (l.recognizer as TapGestureRecognizer).onTap!();
      expect(link, 'https://nih.gov/x');
      (s.firstWhere((x) => x.text == '+1 650-555-0198').recognizer as TapGestureRecognizer).onTap!();
      expect(phone, '+16505550198');
    });

    testWidgets('blocks: quote and code get their own containers', (tester) async {
      await tester.pumpWidget(_app(MessageText(
        text: '> careful\n```\nx = 1\n```\n- one\n- two',
        style: messageBodyStyle(isMine: true),
        isMine: true,
      )));
      expect(find.byKey(const ValueKey('rich-quote')), findsOneWidget);
      expect(find.byKey(const ValueKey('rich-code')), findsOneWidget);
      expect(find.text('x = 1'), findsOneWidget);
      expect(find.text('•  '), findsNWidgets(2));
    });

    testWidgets('search highlight marks every case-insensitive hit', (tester) async {
      await tester.pumpWidget(_app(MessageText(
        text: 'CT today, ct tomorrow',
        style: messageBodyStyle(isMine: false),
        isMine: false,
        highlight: 'ct',
      )));
      final hits = spans(tester).where((x) => x.style?.backgroundColor != null).toList();
      expect(hits.map((x) => x.text), ['CT', 'ct']);
    });
  });

  testWidgets('unread divider', (tester) async {
    await tester.pumpWidget(_app(const UnreadDivider(count: 3)));
    expect(find.byKey(const ValueKey('unread-divider')), findsOneWidget);
    expect(find.text(Strings.chatUnreadDivider(3)), findsOneWidget);
    expect(Strings.chatUnreadDivider(1), isNot(Strings.chatUnreadDivider(2)), reason: 'singular / plural');
  });

  group('external link confirm', () {
    testWidgets('cancel opens nothing; confirm opens; phone wording', (tester) async {
      final opener = FakeUrlOpener();
      final out = <bool?>[];
      await tester.pumpWidget(_opener(
        (ctx) => confirmAndOpenExternal(ctx, url: 'https://nih.gov/x', opener: opener),
        out,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-link-dialog')), findsOneWidget);
      expect(find.text('https://nih.gov/x'), findsOneWidget);
      expect(find.text(Strings.chatOpenLinkTitle), findsOneWidget);
      await tester.tap(find.text(Strings.cancel));
      await tester.pumpAndSettle();
      expect(out, [false]);
      expect(opener.opened, isEmpty);

      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-link-confirm')));
      await tester.pumpAndSettle();
      expect(out, [false, true]);
      expect(opener.opened, ['https://nih.gov/x']);

      final out2 = <bool?>[];
      await tester.pumpWidget(_opener(
        (ctx) => confirmAndOpenExternal(ctx, url: 'tel:+16505550198', opener: opener, isPhone: true),
        out2,
      ));
      await tester.tap(find.byKey(const ValueKey('open')));
      await tester.pumpAndSettle();
      expect(find.text(Strings.chatCallNumberTitle), findsOneWidget);
      expect(find.text('+16505550198'), findsOneWidget, reason: 'tel: prefix hidden');
      expect(find.text('Call'), findsOneWidget);
    });
  });
}
