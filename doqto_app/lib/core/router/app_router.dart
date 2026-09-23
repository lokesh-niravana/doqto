import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/organization.dart';
import '../../state/auth_state.dart';
import '../../data/services/auth_broker.dart';
import '../../ui/screens/auth/otp_screen.dart';
import '../../ui/screens/auth/login_screen.dart';
import '../../ui/screens/auth/registration_screen.dart';
import '../../ui/screens/chat/chat_details_screen.dart';
import '../../ui/screens/chat/chat_list_screen.dart';
import '../../ui/screens/chat/chat_thread_screen.dart';
import '../../ui/screens/chat/create_group_screen.dart';
import '../../ui/screens/groups/create_group_flow_screen.dart';
import '../../ui/screens/groups/group_detail_screen.dart';
import '../../ui/screens/groups/groups_tab_screen.dart';
import '../../ui/screens/home/main_shell.dart';
import '../../ui/screens/my_org/my_org_screen.dart';
import '../../ui/screens/network/connections_screen.dart';
import '../../ui/screens/network/invitations_screen.dart';
import '../../ui/screens/network/network_tab_screen.dart';
import '../../ui/screens/org/create_org_screen.dart';
import '../../ui/screens/org/join_org_screen.dart';
import '../../ui/screens/org/org_selection_screen.dart';
import '../../ui/screens/org/pending_verification_screen.dart';
import '../../ui/screens/people/people_search_screen.dart';
import '../../ui/screens/people/person_profile_screen.dart';
import '../../ui/screens/profile/profile_edit_screen.dart';
import '../../ui/screens/profile/profile_screen.dart';
import '../../ui/screens/settings/settings_screen.dart';
import '../../ui/screens/voice_broadcast/voice_broadcast_screen.dart';
import '../../ui/screens/payments/payments_screen.dart';
import '../../ui/screens/splash/splash_screen.dart';

class AppRoutes {
  AppRoutes._();
  static const splash = '/';
  static const login = '/auth/login';
  static const otp = '/auth/otp';
  static const registration = '/auth/registration';
  static const payments = '/payments';
  static const paywall = '/paywall';
  // Where Stripe sends the browser back (`doqto:///billing`). Not a page.
  static const billing = '/billing';
  static const orgSelection = '/org/select';
  static const createOrg = '/org/create';
  static const joinOrg = '/org/join';
  static const pending = '/org/pending';
  static const chats = '/chats';
  // Put NEW-group under a distinct prefix so it never collides with
  // `/chat/:id`. The colon segment of a UUID would otherwise happily
  // swallow "create-group".
  static const createGroup = '/new-group';
  static String chat(String convId) => '/chat/$convId';
  static String chatDetails(String convId) => '/chat/$convId/details';
  static const myOrg = '/my-org';
  // Networking (M2). Network branch of the shell.
  static const network = '/network';
  static const networkInvitations = '/network/invitations';
  static const networkConnections = '/network/connections';
  // People search (M3) — pushed full-screen over the shell.
  static const peopleSearch = '/people/search';
  // Groups branch (M5). Detail/create/requests live INSIDE the branch so tab
  // state is preserved. `/groups/create` MUST precede `/groups/:id` (the colon
  // segment would otherwise swallow "create").
  static const groups = '/groups';
  static const groupsCreate = '/groups/create';
  static String group(String id) => '/groups/$id';
  static const settings = '/settings';
  static const profile = '/profile';
  static const profileEdit = '/profile/edit';
  static const record = '/record';
  // Addressable person profile by user id (networking M1). Root-level route;
  // the shell retrofit that moves it into a branch is the next pass.
  static String person(String userId) => '/people/$userId';
}

/// Opens a conversation from anywhere in the app.
///
/// `/chat/:id` sits on the root navigator, above the tab shell, so this works
/// from any tab or from a full-screen page and back returns to wherever the
/// chat was opened from.
void openConversation(BuildContext context, String conversationId) {
  context.push(AppRoutes.chat(conversationId));
}

/// Re-evaluates redirects whenever AuthStage (or read-only) changes.
Listenable _authListenable(Ref ref) {
  (AuthStage, bool) key(AuthState s) => (s.stage, s.readOnly);
  final notifier = ValueNotifier(key(ref.read(authProvider)));
  ref.listen(authProvider.select(key), (_, next) => notifier.value = next);
  return notifier;
}

/// Root navigator — auth/org/splash + full-screen pushes (profile, settings,
/// record, person profile, people search) live here, ABOVE the tab shell.
final rootNavigatorKey = GlobalKey<NavigatorState>(debugLabel: 'root');
final _chatsNavKey = GlobalKey<NavigatorState>(debugLabel: 'branch-chats');
final _networkNavKey = GlobalKey<NavigatorState>(debugLabel: 'branch-network');
final _groupsNavKey = GlobalKey<NavigatorState>(debugLabel: 'branch-groups');
final _myOrgNavKey = GlobalKey<NavigatorState>(debugLabel: 'branch-myorg');

final routerProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    navigatorKey: rootNavigatorKey,
    initialLocation: AppRoutes.splash,
    routes: [
      // --- Pre-shell flows (full-screen, root navigator) ---
      GoRoute(
        path: AppRoutes.splash,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const SplashScreen(),
      ),
      GoRoute(
        path: AppRoutes.login,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const LoginScreen(),
      ),
      GoRoute(
        path: AppRoutes.otp,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) => OtpScreen(challenge: state.extra as PhoneChallenge),
      ),
      GoRoute(
        path: AppRoutes.registration,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const RegistrationScreen(),
      ),
      GoRoute(
        path: AppRoutes.payments,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const PaymentsScreen(),
      ),
      GoRoute(
        path: AppRoutes.paywall,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const PaymentsScreen(mode: PaymentsMode.paywall),
      ),
      // The resume hook already re-checks billing; the link only needs to land
      // somewhere real. A doctor still unpaid is sent on to the paywall by the
      // top-level redirect before this one runs.
      GoRoute(
        path: AppRoutes.billing,
        redirect: (_, _) => AppRoutes.chats,
      ),
      GoRoute(
        path: AppRoutes.orgSelection,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const OrgSelectionScreen(),
      ),
      GoRoute(
        path: AppRoutes.createOrg,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const CreateOrgScreen(),
      ),
      GoRoute(
        path: AppRoutes.joinOrg,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const JoinOrgScreen(),
      ),
      GoRoute(
        path: AppRoutes.pending,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const PendingVerificationScreen(),
      ),

      // --- Full-screen creation flows (root navigator, no tab bar) ---
      // `/groups/create` MUST be declared before the shell: the shell's
      // `/groups/:id` would otherwise swallow "create".
      GoRoute(
        path: AppRoutes.groupsCreate,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const CreateGroupFlowScreen(),
      ),
      GoRoute(
        path: AppRoutes.createGroup,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const CreateGroupScreen(),
      ),

      // --- The 4-tab shell (indexed stack, per-branch state preserved) ---
      StatefulShellRoute.indexedStack(
        builder: (_, s, navigationShell) =>
            MainShell(navigationShell: navigationShell),
        branches: [
          // Branch 0 — Chats. The thread itself is NOT here: it renders
          // full-screen above the shell (see below) so the tab bar gets out
          // of the way while you are reading and typing.
          StatefulShellBranch(
            navigatorKey: _chatsNavKey,
            routes: [
              GoRoute(
                path: AppRoutes.chats,
                builder: (_, s) => const ChatListScreen(),
              ),
            ],
          ),
          // Branch 1 — Network.
          StatefulShellBranch(
            navigatorKey: _networkNavKey,
            routes: [
              GoRoute(
                path: AppRoutes.network,
                builder: (_, s) => const NetworkTabScreen(),
              ),
              GoRoute(
                path: AppRoutes.networkInvitations,
                builder: (_, s) => const InvitationsScreen(),
              ),
              GoRoute(
                path: AppRoutes.networkConnections,
                builder: (_, s) => const ConnectionsScreen(),
              ),
            ],
          ),
          // Branch 2 — Groups (M5). The detail lives inside the branch so tab
          // state is preserved; creation is full-screen above the shell.
          StatefulShellBranch(
            navigatorKey: _groupsNavKey,
            routes: [
              GoRoute(
                path: AppRoutes.groups,
                builder: (_, s) => const GroupsTabScreen(),
              ),
              GoRoute(
                path: '/groups/:id',
                builder: (_, state) =>
                    GroupDetailScreen(groupId: state.pathParameters['id']!),
              ),
            ],
          ),
          // Branch 3 — My Org.
          StatefulShellBranch(
            navigatorKey: _myOrgNavKey,
            routes: [
              GoRoute(
                path: AppRoutes.myOrg,
                builder: (_, s) => const MyOrgScreen(),
              ),
            ],
          ),
        ],
      ),

      // --- Full-screen pushes OVER the shell (root navigator) ---
      // The conversation covers the tab bar. More specific
      // `/chat/:id/details` precedes `/chat/:id`.
      GoRoute(
        path: '/chat/:id/details',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            ChatDetailsScreen(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chat/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            ChatThreadScreen(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoutes.settings,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.profile,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) => ProfileScreen(member: state.extra as OrgMember?),
      ),
      GoRoute(
        path: AppRoutes.profileEdit,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const ProfileEditScreen(),
      ),
      GoRoute(
        path: AppRoutes.record,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const VoiceBroadcastScreen(),
      ),
      // `/people/search` MUST precede `/people/:userId` — the colon segment
      // would otherwise swallow "search".
      GoRoute(
        path: AppRoutes.peopleSearch,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const PeopleSearchScreen(),
      ),
      GoRoute(
        path: '/people/:userId',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            PersonProfileScreen(userId: state.pathParameters['userId']!),
      ),
    ],
    refreshListenable: _authListenable(ref),
    redirect: (context, state) {
      final auth = ref.read(authProvider);
      final loc = state.matchedLocation;
      if (auth.stage == AuthStage.unknown) return null;
      final inAuthFlow = [
        AppRoutes.splash,
        AppRoutes.login,
        AppRoutes.otp,
        AppRoutes.registration,
      ].contains(loc);
      final inOrgFlow = [
        AppRoutes.orgSelection,
        AppRoutes.createOrg,
        AppRoutes.joinOrg,
        AppRoutes.pending,
      ].contains(loc);
      if (auth.stage == AuthStage.signedOut &&
          (!inAuthFlow || loc == AppRoutes.registration)) {
        // Your details is the second half of sign-up: it needs the session a
        // verified phone (or, later, social sign-in) creates.
        return AppRoutes.login;
      }
      if (auth.stage == AuthStage.needsRegistration && loc != AppRoutes.registration) {
        return AppRoutes.registration;
      }
      if (auth.stage == AuthStage.needsPayment && loc != AppRoutes.payments) {
        return AppRoutes.payments;
      }
      // "Read my messages": a lapsed doctor may go anywhere past onboarding.
      // Sending still 402s, and the 402 clears read-only.
      final reading = auth.readOnly &&
          !inAuthFlow &&
          !inOrgFlow &&
          loc != AppRoutes.payments;
      if (auth.stage == AuthStage.needsSubscription &&
          loc != AppRoutes.paywall &&
          !reading) {
        return AppRoutes.paywall;
      }
      if (auth.stage == AuthStage.needsOrg && !inOrgFlow) {
        return AppRoutes.orgSelection;
      }
      if (auth.stage == AuthStage.pendingVerification && loc != AppRoutes.pending) {
        return AppRoutes.pending;
      }
      // Signed-in user shouldn't be stuck on the pending screen or any of the
      // pre-auth / org-onboarding flows. Push them to chats.
      if (auth.stage == AuthStage.signedIn &&
          (inAuthFlow ||
              inOrgFlow ||
              loc == AppRoutes.payments ||
              loc == AppRoutes.paywall)) {
        return AppRoutes.chats;
      }
      return null;
    },
  );
});
