import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/di/providers.dart';
import '../../core/tokens/colors.dart';
import '../../data/api/websocket_client.dart';
import 'inline_banner.dart';

/// Thin amber strip under the app bar while the realtime socket is down —
/// the standard "Connecting…" cue. Zero-height when connected.
///
/// Thin wrapper over [InlineBanner] (M0); WS-state wiring unchanged.
class ConnectivityBanner extends ConsumerWidget {
  const ConnectivityBanner({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final state = ref.watch(wsConnStateProvider).value ?? WsConnState.connected;
    final offline = state != WsConnState.connected;
    return InlineBanner(
      tone: BannerTone.warn,
      text: 'Connecting…',
      visible: offline,
      leading: SizedBox(
        width: 10,
        height: 10,
        child: CircularProgressIndicator(
          strokeWidth: 1.5,
          color: AppColors.amberText,
        ),
      ),
    );
  }
}
