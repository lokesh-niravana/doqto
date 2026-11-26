import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/motion.dart';
import '../../../state/auth_state.dart';
import '../../widgets/load_failed.dart';

/// Splash: the white mark on black. A launch that takes longer than a
/// second (slow network, token refresh) adds a small spinner under the mark,
/// and the pane is named "Loading" for VoiceOver throughout.
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
  bool _busy = false;

  /// True once the launch has run long enough to deserve a progress mark.
  bool _slow = false;
  Timer? _slowTimer;

  @override
  void initState() {
    super.initState();
    _slowTimer = Timer(const Duration(seconds: 1), () {
      if (mounted) setState(() => _slow = true);
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _bootstrap());
  }

  @override
  void dispose() {
    _slowTimer?.cancel();
    super.dispose();
  }

  Future<void> _bootstrap() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(authProvider.notifier).bootstrap();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
    if (!mounted) return;
    _leave(ref.read(authProvider).stage);
  }

  /// Moves on once the stage is settled. `unreachable` stays here: the
  /// session is intact, only the server could not be reached, so the pane
  /// below offers Retry instead of the login screen.
  void _leave(AuthStage stage) {
    final route = switch (stage) {
      AuthStage.signedIn => AppRoutes.chats,
      AuthStage.pendingVerification => AppRoutes.pending,
      AuthStage.needsOrg => AppRoutes.orgSelection,
      AuthStage.needsRegistration => AppRoutes.registration,
      AuthStage.pinRequired => AppRoutes.pinGate,
      AuthStage.signedOut => AppRoutes.login,
      AuthStage.unknown || AuthStage.unreachable => null,
    };
    if (route != null) context.go(route);
  }

  @override
  Widget build(BuildContext context) {
    // The notifier also re-runs the launch check on app resume; when that
    // settles while this pane is up, move on.
    ref.listen<AuthState>(authProvider, (prev, next) {
      if (_busy || prev?.stage != AuthStage.unreachable) return;
      _leave(next.stage);
    });
    final unreachable = ref.watch(
        authProvider.select((s) => s.stage == AuthStage.unreachable));
    if (unreachable) {
      return Scaffold(
        body: SafeArea(
          child: Center(
            child: SingleChildScrollView(
              child: LoadFailed(
                message: Strings.splashUnreachable,
                loading: _busy,
                onRetry: _bootstrap,
              ),
            ),
          ),
        ),
      );
    }
    return AnnotatedRegion<SystemUiOverlayStyle>(
      value: SystemUiOverlayStyle.light, // black background needs light icons
      child: Scaffold(
        backgroundColor: Colors.black,
        body: Semantics(
          key: const ValueKey('splash-loading'),
          container: true,
          liveRegion: true,
          label: Strings.loading,
          child: ExcludeSemantics(
            child: Center(
              // The logo stays centred: the spinner's slot is reserved above
              // and below so it appears without moving the mark.
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const SizedBox(height: 20 + 24),
                  const SizedBox(
                    width: 120,
                    child:
                        Image(image: AssetImage('assets/splash_logo_white.png')),
                  ),
                  const SizedBox(height: 24),
                  SizedBox.square(
                    dimension: 20,
                    child: _slow
                        ? CircularProgressIndicator(
                            key: const ValueKey('splash-spinner'),
                            strokeWidth: 2,
                            color: Colors.white,
                            // Reduce Motion: a still arc instead of a spin.
                            value: AppMotion.reduced(context) ? 0.75 : null,
                          )
                        : null,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
