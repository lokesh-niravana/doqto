import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/colors.dart';

/// Asks before signing out; true when the user confirms.
///
/// Signing out wipes this phone's cached chats and anything still waiting to
/// send, and getting back in means signing in again (phone code, Apple or
/// Google — the wording names none of them), so every sign-out
/// button — Settings, Profile and the gate screens (PIN, registration,
/// organisation selection, pending verification) — goes through this dialog.
Future<bool> confirmSignOut(BuildContext context) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Sign out?'),
      content: const Text(Strings.signOutConfirmBody),
      actions: [
        TextButton(
          key: const ValueKey('sign-out-cancel'),
          onPressed: () => Navigator.of(ctx).pop(false),
          child: const Text('Cancel'),
        ),
        TextButton(
          key: const ValueKey('sign-out-confirm'),
          onPressed: () => Navigator.of(ctx).pop(true),
          style: TextButton.styleFrom(foregroundColor: AppColors.red),
          child: const Text('Sign out'),
        ),
      ],
    ),
  );
  return confirmed == true;
}
