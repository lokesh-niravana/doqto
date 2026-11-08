import 'dart:io';

import 'package:hive_flutter/hive_flutter.dart';

import 'package:doqto_app/data/services/settings_store.dart';

/// A [SettingsStore] over a real Hive box in a temp dir, for widget tests of
/// the batch-6 settings screens. Call [open] in `setUpAll`, [fresh] in
/// `setUp` and [close] in `tearDownAll`.
///
/// Every test gets its own box rather than `clear()` on a shared one: a
/// write started inside a `testWidgets` fake-async zone can stay pending
/// after the test ends, and a `clear()` on that box would then wait on its
/// write lock forever.
class TempSettingsStore {
  late Directory _tmp;
  late Box<dynamic> box;
  late SettingsStore store;
  String _name = '';
  int _n = 0;

  Future<void> open(String name) async {
    _name = name;
    _tmp = await Directory.systemTemp.createTemp('doqto-$name-');
    Hive.init(_tmp.path);
    await fresh();
  }

  Future<void> fresh() async {
    box = await Hive.openBox<dynamic>('${_name}_${_n++}');
    store = SettingsStore(box: box);
  }

  Future<void> close() async {
    try {
      await _tmp.delete(recursive: true);
    } catch (_) {}
  }
}
