import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../state/app_meta_state.dart';
import '../screens/settings/force_update_screen.dart';

/// Min-version gate (batch 6): replaces the whole app with
/// [ForceUpdateScreen] while this build is below the store minimum. Sits in
/// MaterialApp.builder, so theme and directionality are already there.
class ForceUpdateGate extends ConsumerWidget {
  final Widget child;
  const ForceUpdateGate({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(forceUpdateProvider)) return child;
    final message = ref.watch(minVersionProvider).asData?.value?.message;
    return ForceUpdateScreen(
      key: const ValueKey('force-update-screen'),
      message: (message == null || message.isEmpty) ? null : message,
    );
  }
}
