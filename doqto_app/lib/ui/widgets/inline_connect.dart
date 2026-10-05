import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/constants/strings.dart';
import '../../core/di/providers.dart';
import '../../core/tokens/colors.dart';
import '../../core/utils/error_messages.dart';
import 'primary_button.dart';

/// A minimal connect affordance for a person row (search, suggestions). PersonCard carries only a
/// degree (not the full relationship), so this tracks invite state locally:
/// idle → optimistic Pending on tap, calling [NetworkRepository.sendInvitation];
/// rolls back + error-haptics on failure. The full state machine (accept /
/// withdraw) lives on the profile screen via ConnectButton.
class InlineConnect extends ConsumerStatefulWidget {
  final String userId;
  const InlineConnect({
    super.key,
    required this.userId,
    this.onSent,
    this.compact = false,
  });

  /// A small pill instead of a full button, for rows where the name and the
  /// line under it need the width (suggestions).
  final bool compact;

  /// Called once the invitation is sent (e.g. to hide a suggestion later).
  final VoidCallback? onSent;

  @override
  ConsumerState<InlineConnect> createState() => InlineConnectState();
}

class InlineConnectState extends ConsumerState<InlineConnect> {
  bool _pending = false;
  bool _busy = false;

  Future<void> _connect() async {
    if (_busy || _pending) return;
    setState(() {
      _pending = true; // optimistic
      _busy = true;
    });
    try {
      await ref.read(networkRepositoryProvider).sendInvitation(widget.userId);
      widget.onSent?.call();
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text(Strings.netInviteSentToast)),
        );
      }
    } catch (e) {
      HapticFeedback.heavyImpact();
      if (mounted) {
        setState(() {
          _pending = false;
          _busy = false;
        });
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.compact) {
      final pending = _pending;
      return SizedBox(
        height: 34,
        child: TextButton(
          onPressed: pending ? null : _connect,
          style: TextButton.styleFrom(
            padding: const EdgeInsets.symmetric(horizontal: 14),
            minimumSize: const Size(0, 34),
            backgroundColor: pending ? AppColors.gray100 : AppColors.medBlue,
            foregroundColor: AppColors.white,
            disabledForegroundColor: AppColors.gray600,
            shape: const StadiumBorder(),
            textStyle: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
          ),
          child: Text(pending ? Strings.netPending : Strings.netConnect),
        ),
      );
    }
    if (_pending) {
      return AppButton(
        label: Strings.netPending,
        variant: AppButtonVariant.secondary,
        loading: _busy,
        onPressed: null,
      );
    }
    return AppButton(
      label: Strings.netConnect,
      icon: Icons.person_add_alt_1,
      onPressed: _connect,
    );
  }
}
