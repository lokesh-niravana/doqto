import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../state/auth_state.dart';

/// Splash: the white mark on black, nothing else.
///
/// It holds only as long as [AuthState.bootstrap] takes — there is no minimum
/// display time, so a warm start moves straight through instead of parking the
/// user in front of a logo.
class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  Future<void> _bootstrap() async {
    await ref.read(authProvider.notifier).bootstrap();
    if (!mounted) return;
    final stage = ref.read(authProvider).stage;
    context.go(switch (stage) {
      AuthStage.signedIn => AppRoutes.chats,
      AuthStage.pendingVerification => AppRoutes.pending,
      AuthStage.needsOrg => AppRoutes.orgSelection,
      AuthStage.needsRegistration => AppRoutes.registration,
      AuthStage.needsPayment => AppRoutes.payments,
      AuthStage.needsSubscription => AppRoutes.paywall,
      _ => AppRoutes.login,
    });
  }

  @override
  Widget build(BuildContext context) {
    return const AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // black background needs light icons
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: SizedBox(
            width: 120,
            child: Image(image: AssetImage('assets/splash_logo_white.png')),
          ),
        ),
      ),
    );
  }
}
