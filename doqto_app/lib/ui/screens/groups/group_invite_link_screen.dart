import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../state/groups_state.dart';
import '../../widgets/primary_button.dart';

/// Landing for an invite link (`doqto:///g/<token>`): joins through the
/// token, then replaces itself with the group. An expired, revoked or used-up
/// link shows why, with a way back to Groups. Already a member → straight in.
class GroupInviteLinkScreen extends ConsumerStatefulWidget {
  final String token;
  const GroupInviteLinkScreen({super.key, required this.token});

  @override
  ConsumerState<GroupInviteLinkScreen> createState() =>
      _GroupInviteLinkScreenState();
}

class _GroupInviteLinkScreenState extends ConsumerState<GroupInviteLinkScreen> {
  Object? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _join());
  }

  Future<void> _join() async {
    setState(() => _error = null);
    try {
      final result = await ref
          .read(groupsRepositoryProvider)
          .acceptLinkInvite(widget.token);
      ref.invalidate(myGroupsProvider);
      ref.invalidate(groupDetailProvider(result.groupId));
      if (!mounted) return;
      if (result.joined) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.groupJoinedViaLink)),
        );
      }
      context.pushReplacement(AppRoutes.group(result.groupId));
    } catch (e) {
      if (mounted) setState(() => _error = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(title: const Text(Strings.groupInfoTitle)),
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: error == null
              ? Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: AppSpacing.md),
                    Text(Strings.groupJoiningViaLink, style: AppText.body),
                  ],
                )
              : Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.link_off_rounded,
                        size: 40, color: AppColors.textMuted),
                    const SizedBox(height: AppSpacing.md),
                    Text(
                      ErrorMessages.forApi(error),
                      style: AppText.body,
                      textAlign: TextAlign.center,
                    ),
                    const SizedBox(height: AppSpacing.lg),
                    AppButton(
                      label: Strings.retry,
                      variant: AppButtonVariant.secondary,
                      onPressed: _join,
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    TextButton(
                      onPressed: () => context.go(AppRoutes.groups),
                      child: const Text(Strings.netTabGroups),
                    ),
                  ],
                ),
        ),
      ),
    );
  }
}
