import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/strings.dart';
import '../../core/security/device_integrity.dart';
import 'inline_banner.dart';

/// Shown in release builds only; tests flip it on.
final deviceIntegrityBannerEnabledProvider = Provider<bool>((_) => kReleaseMode);

/// Warning strip above the whole app when the device looks jailbroken or
/// rooted (batch 7). Mounted from `MaterialApp.router(builder:)`, so it sits
/// above every route and survives navigation. The strip takes the top safe
/// area itself and hands the rest of the screen a MediaQuery without it.
class DeviceIntegrityBanner extends ConsumerWidget {
  final Widget child;
  const DeviceIntegrityBanner({super.key, required this.child});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!ref.watch(deviceIntegrityBannerEnabledProvider)) return child;
    final modified = ref.watch(deviceIntegrityProvider).asData?.value.modified ?? false;
    if (!modified) return child;
    final top = MediaQuery.paddingOf(context).top;
    return Column(
      children: [
        Container(
          key: const ValueKey('device-integrity-banner'),
          color: InlineBanner.backgroundFor(BannerTone.warn),
          padding: EdgeInsets.only(top: top),
          child: const InlineBanner(
            tone: BannerTone.warn,
            icon: Icons.warning_amber_rounded,
            text: Strings.deviceModifiedBanner,
          ),
        ),
        Expanded(
          child: MediaQuery.removePadding(
            context: context,
            removeTop: true,
            child: child,
          ),
        ),
      ],
    );
  }
}
