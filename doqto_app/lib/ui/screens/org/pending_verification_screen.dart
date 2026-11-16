import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/constants/strings.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../state/auth_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';

class PendingVerificationScreen extends ConsumerStatefulWidget {
  const PendingVerificationScreen({super.key});

  @override
  ConsumerState<PendingVerificationScreen> createState() =>
      _PendingVerificationScreenState();
}

class _PendingVerificationScreenState
    extends ConsumerState<PendingVerificationScreen> {
  // No poll: the verification decision arrives as an `org_updated` socket
  // event (OrgNotifier re-resolves the auth stage). The button below is a
  // manual fallback for a flaky connection.
  bool _checking = false;
  DateTime? _lastChecked;

  Future<void> _checkNow({bool silent = false}) async {
    if (_checking) return;
    setState(() => _checking = true);
    try {
      await ref.read(authProvider.notifier).refreshOrgStatus();
      if (!mounted) return;
      setState(() => _lastChecked = DateTime.now());
    } catch (e) {
      if (silent || !mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  Future<void> _signOut() async {
    await ref.read(authProvider.notifier).signOut();
  }

  @override
  Widget build(BuildContext context) {
    final org = ref.watch(orgProvider).current;
    final suspended = org?.status == OrgStatus.suspended;

    return Scaffold(
      body: SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            children: [
              Expanded(
                child: Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      FadeSlideIn.staggered(
                          0,
                          Container(
                            width: 96,
                            height: 96,
                            decoration: BoxDecoration(
                              color: suspended
                                  ? AppColors.redLight
                                  : AppColors.medBlueLight,
                              shape: BoxShape.circle,
                            ),
                            child: Icon(
                              suspended
                                  ? Icons.cancel_rounded
                                  : Icons.hourglass_top_rounded,
                              size: 48,
                              color: suspended
                                  ? AppColors.red
                                  : AppColors.medBlueDark,
                            ),
                          )),
                      const SizedBox(height: AppSpacing.xl),
                      FadeSlideIn.staggered(
                        1,
                        Text(
                          suspended
                              ? 'Organization not approved'
                              : Strings.orgPendingTitle,
                          style: AppText.display,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.md),
                      FadeSlideIn.staggered(
                        2,
                        Text(
                          suspended
                              ? (org?.reviewNotes?.isNotEmpty == true
                                  ? org!.reviewNotes!
                                  : 'Your organization was not approved. Please contact support for next steps.')
                              : Strings.orgPendingBody,
                          style: AppText.body,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      const SizedBox(height: AppSpacing.xl),
                      if (!suspended)
                        FadeSlideIn.staggered(
                          3,
                          AppButton(
                            label: 'Check verification',
                            icon: Icons.refresh_rounded,
                            loading: _checking,
                            onPressed: _checkNow,
                            expand: true,
                          ),
                        ),
                      if (!suspended) ...[
                        const SizedBox(height: AppSpacing.sm),
                        Text(
                          _lastCheckedLabel(),
                          style: AppText.caption,
                          textAlign: TextAlign.center,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
              TextButton(
                onPressed: _checking ? null : _signOut,
                child: const Text(
                  'Sign out',
                  style: TextStyle(color: AppColors.medBlue),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _lastCheckedLabel() {
    if (_lastChecked == null) return 'Updates arrive automatically';
    final secs = DateTime.now().difference(_lastChecked!).inSeconds;
    if (secs < 5) return 'Just checked';
    if (secs < 60) return 'Last checked ${secs}s ago';
    final mins = secs ~/ 60;
    return 'Last checked ${mins}m ago';
  }
}
