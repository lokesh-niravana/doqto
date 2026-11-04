import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/data/services/chat_document_store.dart';
import 'package:doqto_app/data/services/document_viewer.dart';
import 'package:doqto_app/ui/screens/chat/pdf_viewer_screen.dart';
import 'package:doqto_app/ui/widgets/attachment_bubbles.dart';

class _Viewer implements DocumentViewer {
  final previews = <String>[];
  final external = <String>[];
  bool canPreview = true;
  bool hasApp = true;
  bool pdfBroken = false;

  @override
  Future<bool> preview(String path) async {
    previews.add(path);
    return canPreview;
  }

  @override
  Future<bool> openExternally(String path, String mimeType) async {
    external.add('$mimeType $path');
    return hasApp;
  }

  @override
  Future<List<PdfPageSize>> pdfOpen(String path) async {
    if (pdfBroken) throw Exception('password');
    return const [PdfPageSize(600, 800), PdfPageSize(600, 800)];
  }

  @override
  Future<Uint8List> pdfPage(int index, int width) async => _png;

  @override
  Future<void> pdfClose() async {}
}

/// The store has its own tests; here it just has to answer.
class _Store extends ChatDocumentStore {
  _Store() : super(root: () async => Directory.systemTemp);
  bool fail = false;
  final seen = <String>{};

  @override
  Future<File> open(
    String messageId,
    String fileName,
    Future<String> Function() resolveUrl,
  ) async {
    if (fail) throw const HttpException('no');
    if (seen.add(messageId)) await resolveUrl();
    return File('/phone/$messageId/$fileName');
  }
}

/// 1x1 transparent PNG.
final _png = Uint8List.fromList(const [
  137,
  80,
  78,
  71,
  13,
  10,
  26,
  10,
  0,
  0,
  0,
  13,
  73,
  72,
  68,
  82,
  0,
  0,
  0,
  1,
  0,
  0,
  0,
  1,
  8,
  6,
  0,
  0,
  0,
  31,
  21,
  196,
  137,
  0,
  0,
  0,
  13,
  73,
  68,
  65,
  84,
  120,
  156,
  99,
  96,
  0,
  2,
  0,
  0,
  5,
  0,
  1,
  226,
  38,
  5,
  155,
  0,
  0,
  0,
  0,
  73,
  69,
  78,
  68,
  174,
  66,
  96,
  130,
]);

void main() {
  late _Store store;
  late _Viewer viewer;
  var resolved = 0;

  setUp(() {
    store = _Store();
    viewer = _Viewer();
    resolved = 0;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  Widget app(String name) => ProviderScope(
    overrides: [
      documentViewerProvider.overrideWithValue(viewer),
      chatDocumentStoreProvider.overrideWithValue(store),
    ],
    child: MaterialApp(
      home: Scaffold(
        body: FileBubble(
          messageId: 'm1',
          getFileUrl: () async {
            resolved++;
            return 'https://s3.test/a';
          },
          fileName: name,
          isMine: false,
          timestamp: DateTime(2026),
        ),
      ),
    ),
  );

  Future<void> tapBubble(WidgetTester t, String name) async {
    await t.tap(find.text(name));
    await t.pump();
    await t.pump(const Duration(milliseconds: 400));
  }

  testWidgets('iOS: every format stays in the app, nothing external', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(app('labs.xlsx'));
    await tapBubble(t, 'labs.xlsx');
    expect(viewer.previews.single, endsWith('labs.xlsx'));
    expect(viewer.external, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('iOS: an unknown format says so', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    viewer.canPreview = false;
    await t.pumpWidget(app('scan.xyz'));
    await tapBubble(t, 'scan.xyz');
    expect(find.text('This file type can’t be previewed'), findsOneWidget);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: a PDF opens in the app with no prompt', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await t.pumpWidget(app('report.PDF'));
    await tapBubble(t, 'report.PDF');
    expect(find.byType(PdfViewerScreen), findsOneWidget);
    expect(find.text('Open outside Doqto?'), findsNothing);
    expect(viewer.external, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: a locked PDF offers another app', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    viewer.pdfBroken = true;
    await t.pumpWidget(app('locked.pdf'));
    await tapBubble(t, 'locked.pdf');
    expect(find.text('This PDF can’t be shown here'), findsOneWidget);
    expect(find.text('Open in another app'), findsWidgets);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: Word leaves Doqto only after the user agrees', (
    t,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    await t.pumpWidget(app('note.docx'));
    await tapBubble(t, 'note.docx');
    expect(find.text('Open outside Doqto?'), findsOneWidget);
    await t.tap(find.text('Cancel'));
    await t.pumpAndSettle();
    expect(viewer.external, isEmpty, reason: 'cancel means nothing left');

    await tapBubble(t, 'note.docx');
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    expect(viewer.external.single, contains('wordprocessingml'));
    expect(viewer.external.single, endsWith('note.docx'));
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('Android: no app that can open it says so', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    viewer.hasApp = false;
    await t.pumpWidget(app('labs.xlsx'));
    await tapBubble(t, 'labs.xlsx');
    await t.tap(find.text('Open'));
    await t.pumpAndSettle();
    expect(
      find.text('No app on this phone can open this file'),
      findsOneWidget,
    );
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a failed download says so and opens nothing', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    store.fail = true;
    await t.pumpWidget(app('labs.xlsx'));
    await tapBubble(t, 'labs.xlsx');
    expect(find.text('Could not download the file'), findsOneWidget);
    expect(viewer.previews, isEmpty);
    debugDefaultTargetPlatformOverride = null;
  });

  testWidgets('a second open does not ask the server again', (t) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    await t.pumpWidget(app('labs.xlsx'));
    await tapBubble(t, 'labs.xlsx');
    await tapBubble(t, 'labs.xlsx');
    expect(viewer.previews, hasLength(2));
    expect(resolved, 1);
    debugDefaultTargetPlatformOverride = null;
  });
}
