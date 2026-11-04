import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;

import 'package:doqto_app/data/services/chat_document_store.dart';

void main() {
  late Directory root;
  late int downloads;
  late ChatDocumentStore store;

  Future<void> fakeDownload(String url, File target) async {
    downloads++;
    await target.writeAsString('from $url');
  }

  Future<String> url() async => 'https://s3.test/signed-$downloads';

  setUp(() async {
    root = await Directory.systemTemp.createTemp('docs');
    downloads = 0;
    store = ChatDocumentStore(root: () async => root, download: fakeDownload);
  });
  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test('downloads once, then serves the phone copy', () async {
    final first = await store.open('m1', 'report.docx', url);
    final second = await store.open('m1', 'report.docx', url);
    expect(downloads, 1);
    expect(second.path, first.path);
  });

  test('keeps the real name: viewers pick the format from it', () async {
    final f = await store.open('m1', 'Lab Results.xlsx', url);
    expect(p.basename(f.path), 'Lab Results.xlsx');
  });

  test('double tap shares one download', () async {
    await Future.wait([
      store.open('m1', 'a.pdf', url),
      store.open('m1', 'a.pdf', url),
    ]);
    expect(downloads, 1);
  });

  test('a name from the sender cannot escape the folder', () async {
    final f = await store.open('m1', '../../../etc/passwd.pdf', url);
    expect(p.isWithin(root.path, f.path), isTrue);
    expect(p.basename(f.path), 'passwd.pdf');
    expect(ChatDocumentStore.safeName('..'), 'document');
    expect(ChatDocumentStore.safeName(r'a\b.pdf'), 'b.pdf');
    final long = ChatDocumentStore.safeName('${'x' * 300}.pdf');
    expect(long.length, 120);
    expect(long.endsWith('.pdf'), isTrue);
  });

  test('a failed download leaves nothing and can retry', () async {
    var fail = true;
    final flaky = ChatDocumentStore(
      root: () async => root,
      download: (u, t) async {
        await t.writeAsString('partial');
        if (fail) throw const HttpException('dropped');
        await fakeDownload(u, t);
      },
    );
    await expectLater(flaky.open('m1', 'a.pdf', url), throwsA(anything));
    expect(await root.list().isEmpty, isTrue);
    fail = false;
    expect(
      await (await flaky.open('m1', 'a.pdf', url)).readAsString(),
      startsWith('from'),
    );
  });

  test('the sender’s upload is filed without a download', () async {
    final src = File(p.join(root.parent.path, 'upload_${root.hashCode}.tmp'));
    await src.writeAsString('mine');
    addTearDown(() => src.delete());
    await store.seed('m1', 'mine.pdf', src);
    final f = await store.open('m1', 'mine.pdf', url);
    expect(downloads, 0);
    expect(await f.readAsString(), 'mine');
  });

  test('evict removes one message, clear removes everything', () async {
    final a = await store.open('m1', 'a.pdf', url);
    final b = await store.open('m2', 'b.pdf', url);
    await store.evict('m1');
    expect(await a.exists(), isFalse);
    expect(await b.exists(), isTrue);
    await store.clear();
    expect(await b.exists(), isFalse);
    expect(await root.list().isEmpty, isTrue);
  });

  test('unused documents go stale, recently opened ones stay', () async {
    final old = await store.open('old', 'a.pdf', url);
    final used = await store.open('used', 'b.pdf', url);
    final past = DateTime.now().subtract(const Duration(days: 40));
    await old.setLastModified(past);
    await used.setLastModified(past);

    final next = ChatDocumentStore(
      root: () async => root,
      download: fakeDownload,
    );
    await next.open('used', 'b.pdf', url); // first use sweeps and touches
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(await old.exists(), isFalse);
    expect(await used.exists(), isTrue);
  });
}
