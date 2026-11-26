import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/utils/error_messages.dart';

/// Runs a pull-to-refresh and says so when it fails.
///
/// The notifiers' `refresh()` keeps the stale list on a failure, which is
/// right for the silent refreshes (a socket event, coming back to the app)
/// but left a pull looking like it had worked. Pass a refresh that throws
/// (`refresh(rethrowOnError: true)`); the list stays as it was and a snackbar
/// carries the reason.
Future<void> refreshWithFeedback(
  BuildContext context,
  Future<void> Function() refresh,
) async {
  // Captured first: the pulled list may be gone by the time this fails.
  final messenger = ScaffoldMessenger.maybeOf(context);
  try {
    await refresh();
  } catch (e) {
    messenger
      ?..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ),
      );
  }
}
