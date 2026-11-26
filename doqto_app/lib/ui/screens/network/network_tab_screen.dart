import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/strings.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../data/models/network_profile.dart';
import '../../../state/network_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/invitation_card.dart';
import '../../widgets/person_card_row.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/section_card.dart';
import 'suggestions_screen.dart';
import '../home/main_shell.dart';
import '../../widgets/refresh_feedback.dart';

/// Network tab: an invitations preview (top ≤2 received pending), a connections
/// preview with a count + "Manage all", "Recommended for you" (top 5 + See all)
/// and a search entry. Pull-to-refresh refetches all three.
class NetworkTabScreen extends ConsumerWidget {
  const NetworkTabScreen({super.key});

  static const _invitePreviewCount = 2;
  static const _connectionPreviewCount = 5;
  static const _suggestionPreviewCount = 5;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final invitesAsync = ref.watch(invitationsProvider);
    final connectionsAsync = ref.watch(connectionsProvider);
    final suggestions =
        ref.watch(suggestionsProvider).valueOrNull ?? const <PersonCard>[];

    final invites = invitesAsync.valueOrNull ?? const <Invitation>[];
    final connections = connectionsAsync.valueOrNull ?? const <PersonCard>[];
    // Either list still on its way with nothing to show for it is loading:
    // with `&&` the first answer in painted "no connections yet" (or the
    // empty-network pane) while the other request was still pending.
    final loading = (invitesAsync.isLoading && !invitesAsync.hasValue) ||
        (connectionsAsync.isLoading && !connectionsAsync.hasValue);
    final isEmpty = !loading &&
        invites.isEmpty &&
        connections.isEmpty &&
        suggestions.isEmpty;
    // Nothing to show AND a load failed: that is an error, not an empty
    // network. (With anything cached on screen, the list stays and
    // pull-to-refresh retries.)
    // Suggestions are a bonus: their failure alone leaves the true "empty
    // network" pane.
    final settled = !invitesAsync.isLoading && !connectionsAsync.isLoading;
    final Object? loadError = isEmpty && settled
        ? (invitesAsync.error ?? connectionsAsync.error)
        : null;
    void retry() {
      ref.invalidate(invitationsProvider);
      ref.invalidate(connectionsProvider);
      ref.invalidate(suggestionsProvider);
    }

    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: const Text(Strings.netMyNetwork),
        actions: [
          // Always present: the inbox is the only place to see and withdraw
          // requests you SENT, and those exist whether or not anyone has
          // written to you.
          _InvitationsAction(count: invites.length),
          IconButton(
            tooltip: Strings.netDiscoverPeople,
            icon: const Icon(Icons.search),
            onPressed: () => context.push(AppRoutes.peopleSearch),
          ),
        ],
      ),
      body: RefreshIndicator(
        onRefresh: () => refreshWithFeedback(context, () async {
          // All three run to the end; the first failure is the one reported.
          Object? failure;
          Future<void> run(Future<void> Function() refresh) async {
            try {
              await refresh();
            } catch (e) {
              failure ??= e;
            }
          }

          await Future.wait([
            run(() => ref.read(invitationsProvider.notifier).refresh(rethrowOnError: true)),
            run(() => ref.read(connectionsProvider.notifier).refresh(rethrowOnError: true)),
            run(() => ref.read(suggestionsProvider.notifier).refresh(rethrowOnError: true)),
          ]);
          final e = failure;
          if (e != null) throw e;
        }),
        child: loading
            ? const SkeletonList()
            : loadError != null
                ? _ErrorPane(
                    message: ErrorMessages.forApi(loadError),
                    onRetry: retry,
                  )
            : isEmpty
                ? _EmptyNetwork(
                    onDiscover: () => context.push(AppRoutes.peopleSearch),
                  )
                : ListView(
                    physics: const AlwaysScrollableScrollPhysics(),
                    padding: EdgeInsets.only(
                      top: AppSpacing.md,
                      bottom: MediaQuery.paddingOf(context).bottom +
                          kMicButtonRise +
                          AppSpacing.xl,
                    ),
                    children: [
                      if (invites.isNotEmpty)
                        _InvitationsPreview(
                          invitations: invites,
                          previewCount: _invitePreviewCount,
                        ),
                      _ConnectionsPreview(
                        connections: connections,
                        previewCount: _connectionPreviewCount,
                        // Failed with nothing cached: that is not "no
                        // connections yet".
                        error: connectionsAsync.hasError &&
                                !connectionsAsync.hasValue
                            ? connectionsAsync.error
                            : null,
                        onRetry: () => ref.invalidate(connectionsProvider),
                      ),
                      if (suggestions.isNotEmpty)
                        _SuggestionsPreview(
                          suggestions: suggestions,
                          previewCount: _suggestionPreviewCount,
                        ),
                    ],
                  ),
      ),
    );
  }
}

/// App-bar entry to the invitations inbox, badged with the number of requests
/// waiting on you. Tapping through also reaches the Sent tab.
class _InvitationsAction extends StatelessWidget {
  final int count;
  const _InvitationsAction({required this.count});

  @override
  Widget build(BuildContext context) {
    return IconButton(
      tooltip: Strings.netInvitations,
      onPressed: () => context.push(AppRoutes.networkInvitations),
      icon: Stack(
        clipBehavior: Clip.none,
        children: [
          const Icon(Icons.person_add_alt_1_outlined),
          if (count > 0)
            Positioned(
              right: -4,
              top: -4,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                constraints: const BoxConstraints(minWidth: 16),
                decoration: BoxDecoration(
                  color: AppColors.red,
                  borderRadius: BorderRadius.circular(8),
                ),
                // Clamped as the tab bar badge is: at the largest text
                // sizes it grew over the icon it sits on.
                child: MediaQuery.withClampedTextScaling(
                  maxScaleFactor: 1.3,
                  child: Text(
                    count > 99 ? '99+' : '$count',
                    textAlign: TextAlign.center,
                    style: AppText.badge.copyWith(color: AppColors.white),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _InvitationsPreview extends ConsumerWidget {
  final List<Invitation> invitations;
  final int previewCount;
  const _InvitationsPreview({
    required this.invitations,
    required this.previewCount,
  });

  Future<void> _accept(BuildContext context, WidgetRef ref, Invitation inv) =>
      _run(context, ref, () => ref.read(invitationsProvider.notifier).accept(inv),
          Strings.netNowConnectedToast);

  Future<void> _ignore(BuildContext context, WidgetRef ref, Invitation inv) =>
      _run(context, ref, () => ref.read(invitationsProvider.notifier).ignore(inv),
          null);

  Future<void> _run(BuildContext context, WidgetRef ref,
      Future<void> Function() action, String? toast) async {
    try {
      await action();
      if (toast != null && context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(toast)));
      }
    } catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(ErrorMessages.forApi(e)),
          backgroundColor: AppColors.red,
        ));
      }
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shown = invitations.take(previewCount).toList();
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        0,
        AppSpacing.screenHorizontal,
        AppSpacing.lg,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: AppSpacing.xs, bottom: AppSpacing.sm),
            child: Semantics(header: true, child: Text(Strings.netInvitations.toUpperCase(),
                style: AppText.label)),
          ),
          for (final (i, inv) in shown.indexed) ...[
            if (i > 0) const SizedBox(height: AppSpacing.sm),
            FadeSlideIn.staggered(
              i,
              InvitationCard(
                invitation: inv,
                onAccept: () => _accept(context, ref, inv),
                onIgnore: () => _ignore(context, ref, inv),
                onTap: inv.sender != null
                    ? () => context.push(AppRoutes.person(inv.sender!.id))
                    : null,
              ),
            ),
          ],
          if (invitations.length > shown.length) ...[
            const SizedBox(height: AppSpacing.sm),
            _SeeAllButton(
              label: Strings.netSeeAllInvitations(invitations.length),
              onTap: () => context.push(AppRoutes.networkInvitations),
            ),
          ],
        ],
      ),
    );
  }
}

class _ConnectionsPreview extends StatelessWidget {
  final List<PersonCard> connections;
  final int previewCount;

  /// Set when the connections call failed and there is nothing to show for
  /// it: the section says so, with [onRetry], instead of "no connections".
  final Object? error;
  final VoidCallback? onRetry;
  const _ConnectionsPreview({
    required this.connections,
    required this.previewCount,
    this.error,
    this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final shown = connections.take(previewCount).toList();
    return Padding(
      padding: const EdgeInsets.symmetric(
          horizontal: AppSpacing.screenHorizontal),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: AppSpacing.xs, bottom: AppSpacing.sm),
            child: Row(
              children: [
                Semantics(header: true, child: Text(Strings.netYourConnections.toUpperCase(),
                    style: AppText.label)),
                const SizedBox(width: AppSpacing.sm),
                if (connections.isNotEmpty)
                  Text('${connections.length}',
                      style: AppText.label.copyWith(color: AppColors.medBlue)),
              ],
            ),
          ),
          if (connections.isEmpty && error != null)
            SectionCard(
              key: const ValueKey('network-connections-error'),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InlineError(ErrorMessages.forApi(error)),
                  const SizedBox(height: AppSpacing.sm),
                  AppButton(
                    key: const ValueKey('network-connections-retry'),
                    label: Strings.retry,
                    icon: Icons.refresh_rounded,
                    variant: AppButtonVariant.ghost,
                    expand: true,
                    onPressed: onRetry,
                  ),
                ],
              ),
            )
          else if (connections.isEmpty)
            SectionCard(
              child: Text(Strings.netEmptyConnections, style: AppText.caption),
            )
          else ...[
            for (final (i, p) in shown.indexed)
              FadeSlideIn.staggered(
                i,
                PersonCardRow(
                  person: p,
                  onTap: () => context.push(AppRoutes.person(p.id)),
                ),
              ),
            const SizedBox(height: AppSpacing.xs),
            _SeeAllButton(
              label: Strings.netManageAll,
              onTap: () => context.push(AppRoutes.networkConnections),
            ),
          ],
        ],
      ),
    );
  }
}

class _SuggestionsPreview extends StatelessWidget {
  final List<PersonCard> suggestions;
  final int previewCount;
  const _SuggestionsPreview({
    required this.suggestions,
    required this.previewCount,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(
        AppSpacing.screenHorizontal,
        AppSpacing.lg,
        AppSpacing.screenHorizontal,
        0,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(
                left: AppSpacing.xs, bottom: AppSpacing.sm),
            child: Semantics(header: true, child: Text('RECOMMENDED FOR YOU', style: AppText.label)),
          ),
          for (final (i, p) in suggestions.take(previewCount).indexed)
            FadeSlideIn.staggered(i, SuggestionRow(person: p)),
          if (suggestions.length > previewCount) ...[
            const SizedBox(height: AppSpacing.xs),
            _SeeAllButton(
              label: 'See all',
              onTap: () => context.push(AppRoutes.networkSuggestions),
            ),
          ],
        ],
      ),
    );
  }
}

class _SeeAllButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;
  const _SeeAllButton({required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton(
        onPressed: onTap,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(label,
                style: AppText.button.copyWith(color: AppColors.medBlue)),
            const Icon(Icons.chevron_right, size: 18, color: AppColors.medBlue),
          ],
        ),
      ),
    );
  }
}

/// A failed first load. Scrollable so pull-to-refresh still works on it.
class _ErrorPane extends StatelessWidget {
  final String message;
  final VoidCallback onRetry;
  const _ErrorPane({required this.message, required this.onRetry});

  @override
  Widget build(BuildContext context) {
    return ListView(
      key: const ValueKey('network-error'),
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Padding(
          padding: const EdgeInsets.all(AppSpacing.xl),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.wifi_off_rounded, size: 40, color: AppColors.textMuted),
              const SizedBox(height: AppSpacing.md),
              // Announced when it replaces the loading state.
              Semantics(
                container: true,
                liveRegion: true,
                child: Text(message, style: AppText.caption, textAlign: TextAlign.center),
              ),
              const SizedBox(height: AppSpacing.lg),
              AppButton(
                key: const ValueKey('network-retry'),
                label: Strings.retry,
                icon: Icons.refresh_rounded,
                onPressed: onRetry,
              ),
            ],
          ),
        ),
      ],
    );
  }
}

class _EmptyNetwork extends StatelessWidget {
  final VoidCallback onDiscover;
  const _EmptyNetwork({required this.onDiscover});

  @override
  Widget build(BuildContext context) {
    return ListView(
      physics: const AlwaysScrollableScrollPhysics(),
      children: [
        SizedBox(height: MediaQuery.of(context).size.height * 0.22),
        Center(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.xxl),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.people_outline,
                    size: 48, color: AppColors.gray400),
                const SizedBox(height: AppSpacing.lg),
                // Announced when it replaces the loading state.
                Semantics(
                  container: true,
                  liveRegion: true,
                  child: Text(Strings.netEmptyNetwork,
                      style: AppText.body, textAlign: TextAlign.center),
                ),
                const SizedBox(height: AppSpacing.lg),
                AppButton(
                  label: Strings.netDiscoverPeople,
                  icon: Icons.search,
                  onPressed: onDiscover,
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
