import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../core/router/app_router.dart';

/// Back button for a full-screen route that a link can open directly.
///
/// A platform deep link (and `context.go`) replaces the navigation stack, so
/// the screen it lands on is the only route: nothing to pop, and a stock
/// `AppBar` then draws no back button at all. This always draws one. With a
/// route underneath it is the ordinary back button; alone on the stack it
/// goes to the chat list, the app's home.
class RootBackButton extends StatelessWidget {
  const RootBackButton({super.key});

  @override
  Widget build(BuildContext context) {
    // The same test AppBar uses for its implied leading; it also rebuilds
    // this button when the route's position in the stack changes.
    final canPop = ModalRoute.of(context)?.impliesAppBarDismissal ??
        Navigator.of(context).canPop();
    if (canPop) return const BackButton();
    return IconButton(
      key: const ValueKey('root-back-home'),
      tooltip: MaterialLocalizations.of(context).backButtonTooltip,
      icon: const BackButtonIcon(),
      onPressed: () => GoRouter.maybeOf(context)?.go(AppRoutes.chats),
    );
  }
}
