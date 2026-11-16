import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';

import 'package:doqto_app/core/di/providers.dart';
import 'package:doqto_app/core/router/app_router.dart';
import 'package:doqto_app/data/models/conversation.dart';
import 'package:doqto_app/data/models/message.dart';
import 'package:doqto_app/data/services/chat_cache.dart';
import 'package:doqto_app/state/chat_state.dart';
import 'package:doqto_app/state/settings_state.dart';
import 'package:doqto_app/ui/screens/settings/appearance_screen.dart';

import '../support/settings_test_support.dart';

/// Chats & appearance (batch 6): theme / font size choice sheets write
/// through to the store, the preview scales, the switches persist, Keep
/// chats archived goes to the chat cache, and the colour / wallpaper rows
/// push their pickers.
class _Cache extends ChatCache {
  bool keep = true;
  @override
  List<Conversation>? conversations() => null;
  @override
  Future<void> putConversations(List<Conversation> list) async {}
  @override
  Future<void> putMessages(String convId, List<Message> m) async {}
  @override
  List<Message>? messages(String convId) => null;
  @override
  Map<String, String> drafts() => const {};
  @override
  bool keepArchived() => keep;
  @override
  Future<void> setKeepArchived(bool value) async => keep = value;
}

final _hive = TempSettingsStore();
late _Cache _cache;

Widget _app() {
  final router = GoRouter(routes: [
    GoRoute(path: '/', builder: (_, _) => const AppearanceScreen()),
    GoRoute(
      path: AppRoutes.chatThemeDefault,
      builder: (_, _) => const Scaffold(body: Text('theme picker')),
    ),
    GoRoute(
      path: AppRoutes.wallpaperDefault,
      builder: (_, _) => const Scaffold(body: Text('wallpaper picker')),
    ),
  ]);
  return ProviderScope(
    overrides: [
      settingsStoreProvider.overrideWithValue(_hive.store),
      chatCacheProvider.overrideWithValue(_cache),
    ],
    child: MaterialApp.router(routerConfig: router),
  );
}

Future<void> _open(WidgetTester tester) async {
  // Tall surface: the lazy ListView then builds every row.
  tester.view.physicalSize = const Size(800, 2000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(_app());
  await tester.pumpAndSettle();
}

Future<void> _pick(WidgetTester tester, String row, String opt) async {
  await tester.tap(find.byKey(ValueKey(row)));
  await tester.pumpAndSettle();
  await tester.tap(find.byKey(ValueKey(opt)));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => _hive.open('appearance_test'));
  tearDownAll(() => _hive.close());
  setUp(() async {
    await _hive.fresh();
    _cache = _Cache();
  });

  testWidgets('renders every row with the defaults', (tester) async {
    await _open(tester);
    expect(find.byKey(const ValueKey('appearance-list')), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-row-font_size')), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-preview')), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-row-chat_theme')), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-row-wallpaper')), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-switch-enter_is_send')), findsOneWidget);
    expect(find.byKey(const ValueKey('appearance-switch-voice_transcript')), findsOneWidget);
    expect(find.byKey(const ValueKey('settings-switch-keep_archived')), findsOneWidget);
    expect(
      (tester.widget<Text>(find.byKey(const ValueKey('appearance-value-font_size')))).data,
      'Medium',
    );
  });

  testWidgets('font size sheet scales the preview and persists', (tester) async {
    await _open(tester);
    double previewSize() {
      final text = tester.widget<Text>(find.byKey(const ValueKey('appearance-preview')));
      return text.style!.fontSize!;
    }

    final medium = previewSize();
    await _pick(tester, 'appearance-row-font_size', 'appearance-opt-font_size-large');
    expect(previewSize(), greaterThan(medium));
    expect(_hive.store.fontSize, 'large');
    await _pick(tester, 'appearance-row-font_size', 'appearance-opt-font_size-small');
    expect(previewSize(), lessThan(medium));
    expect(_hive.store.fontSize, 'small');
  });

  testWidgets('Enter is send and Voice transcript switches write through', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-switch-enter_is_send')));
    await tester.pumpAndSettle();
    expect(_hive.store.enterIsSend, isFalse);
    await tester.tap(find.byKey(const ValueKey('appearance-switch-voice_transcript')));
    await tester.pumpAndSettle();
    expect(_hive.store.voiceTranscript, isFalse);
    await tester.tap(find.byKey(const ValueKey('appearance-switch-enter_is_send')));
    await tester.pumpAndSettle();
    expect(_hive.store.enterIsSend, isTrue);
  });

  testWidgets('Keep chats archived toggles keepArchivedProvider and the cache', (tester) async {
    await _open(tester);
    final el = tester.element(find.byKey(const ValueKey('appearance-list')));
    final container = ProviderScope.containerOf(el);
    expect(container.read(keepArchivedProvider), isTrue);
    await tester.tap(find.byKey(const ValueKey('settings-switch-keep_archived')));
    await tester.pumpAndSettle();
    expect(container.read(keepArchivedProvider), isFalse);
    expect(_cache.keep, isFalse);
  });

  testWidgets('chat colour row names the stored default', (tester) async {
    // Real IO inside a fake-async test: run it outside the test zone.
    await tester.runAsync(() async {
      await _hive.store.setChatTheme('ocean');
    });
    await _open(tester);
    final chatValue =
        tester.widget<Text>(find.byKey(const ValueKey('appearance-value-chat_theme'))).data;
    expect(chatValue, isNotNull);
    expect(chatValue, isNot('Default'));
  });

  testWidgets('Default chat colour / wallpaper rows push the pickers', (tester) async {
    await _open(tester);
    await tester.tap(find.byKey(const ValueKey('appearance-row-chat_theme')));
    await tester.pumpAndSettle();
    expect(find.text('theme picker'), findsOneWidget);
    Navigator.of(tester.element(find.text('theme picker'))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('appearance-row-wallpaper')));
    await tester.pumpAndSettle();
    expect(find.text('wallpaper picker'), findsOneWidget);
  });
}
