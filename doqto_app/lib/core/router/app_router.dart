import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../data/models/organization.dart';
import '../../state/auth_state.dart';
import '../../data/services/auth_broker.dart';
import '../../ui/screens/auth/otp_screen.dart';
import '../../ui/screens/auth/pin_gate_screen.dart';
import '../../ui/screens/auth/login_screen.dart';
import '../../ui/screens/auth/registration_screen.dart';
import '../../ui/screens/chat/chat_details_screen.dart';
import '../../ui/screens/chat/chat_list_screen.dart';
import '../../ui/screens/chat/chat_thread_screen.dart';
import '../../ui/screens/chat/new_message_screen.dart';
import '../../ui/screens/chat/starred_messages_screen.dart';
import '../../ui/screens/groups/create_group_flow_screen.dart';
import '../../ui/screens/groups/group_detail_screen.dart';
import '../../ui/screens/groups/group_info_screen.dart';
import '../../ui/screens/groups/group_invite_link_screen.dart';
import '../../ui/screens/groups/groups_tab_screen.dart';
import '../../ui/screens/home/main_shell.dart';
import '../../ui/screens/compliance/break_glass_thread_screen.dart';
import '../../ui/screens/my_org/access_requests_screen.dart';
import '../../ui/screens/my_org/my_org_screen.dart';
import '../../ui/screens/my_org/org_policies_screen.dart';
import '../../ui/screens/my_org/org_reports_screen.dart';
import '../../ui/screens/network/connections_screen.dart';
import '../../ui/screens/network/suggestions_screen.dart';
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
import '../../ui/screens/profile/status_screen.dart';
import '../../ui/screens/people/invite_screen.dart';
import '../../ui/screens/settings/app_lock_screen.dart';
import '../../ui/screens/settings/appearance_screen.dart';
import '../../ui/screens/settings/blocked_list_screen.dart';
import '../../ui/screens/settings/change_number_screen.dart';
import '../../ui/screens/settings/chat_theme_picker_screen.dart';
import '../../ui/screens/settings/custom_notifications_screen.dart';
import '../../ui/screens/settings/help_screen.dart';
import '../../ui/screens/settings/language_screen.dart';
import '../../ui/screens/settings/linked_devices_screen.dart';
import '../../ui/screens/settings/notifications_screen.dart';
import '../../ui/screens/settings/privacy_screen.dart';
import '../../ui/screens/settings/settings_screen.dart';
import '../../ui/screens/settings/tone_picker_screen.dart';
import '../../ui/screens/settings/two_step_pin_screen.dart';
import '../../ui/screens/settings/wallpaper_picker_screen.dart';
import '../../ui/screens/voice_broadcast/voice_broadcast_screen.dart';
import '../../ui/screens/splash/splash_screen.dart';
import '../../ui/screens/media/media_gallery_screen.dart';
import '../../ui/screens/storage/manage_storage_screen.dart';
import '../../ui/screens/storage/storage_screen.dart';

class AppRoutes {
  AppRoutes._();
  static const splash = '/';
  static const login = '/auth/login';
  static const otp = '/auth/otp';
  static const registration = '/auth/registration';
  static const orgSelection = '/org/select';
  static const createOrg = '/org/create';
  static const joinOrg = '/org/join';
  static const pending = '/org/pending';
  static const chats = '/chats';
  // Put NEW-group under a distinct prefix so it never collides with
  // `/chat/:id`. The colon segment of a UUID would otherwise happily
  // swallow "create-group".
  static const newMessage = '/new-message';
  static String chat(String convId) => '/chat/$convId';
  // Open a chat scrolled to one message (starred list, batch 4).
  static String chatAt(String convId, String messageId) =>
      Uri(path: '/chat/$convId', queryParameters: {'m': messageId}).toString();
  static String chatDetails(String convId) => '/chat/$convId/details';
  // My starred messages, optionally one chat's (batch 4).
  static const starred = '/starred';
  static String mediaGallery(String convId) => '/chat/$convId/media';
  static const storage = '/storage';
  static const storageManage = '/storage/manage';
  static String starredIn(String convId) =>
      Uri(path: starred, queryParameters: {'c': convId}).toString();
  static const myOrg = '/my-org';
  // Compliance (batch 7): admin tools under My Org, pushed over the shell.
  static const myOrgPolicies = '/my-org/policies';
  static const myOrgAccessRequests = '/my-org/access-requests';
  static String accessRequestMessages(String requestId) =>
      '/my-org/access-requests/$requestId/messages';
  static const myOrgReports = '/my-org/reports';
  // Universal links (https://api.doqto.ai/c/<conversation>, /u/<user>) and
  // the `doqto://` scheme share these paths; `/g/<token>` is the invite link.
  static String conversationLink(String convId) => '/c/$convId';
  static String userLink(String userId) => '/u/$userId';
  // Networking (M2). Network branch of the shell.
  static const network = '/network';
  static const networkInvitations = '/network/invitations';
  static const networkConnections = '/network/connections';
  static const networkSuggestions = '/network/suggestions';
  // People search (M3) — pushed full-screen over the shell.
  static const peopleSearch = '/people/search';
  // Invite a colleague (NPI lookup + share sheet). Root-level, like search.
  static const invite = '/invite';
  static String inviteFor(String q) =>
      Uri(path: invite, queryParameters: {'q': q}).toString();
  // Groups branch (M5). A group itself opens full screen, above the tabs.
  // `/groups/create` MUST precede `/groups/:id` (the colon segment would
  // otherwise swallow "create").
  static const groups = '/groups';
  static const groupsCreate = '/groups/create';
  static String group(String id) => '/groups/$id';
  static String groupInfo(String id) => '/groups/$id/info';
  // An invite link: `doqto:///g/<token>` joins the group and opens it.
  static String groupInviteLink(String token) => '/g/$token';
  static const settings = '/settings';
  static const privacy = '/settings/privacy';
  static const privacyBlocked = '/settings/privacy/blocked';
  // Settings (batch 6).
  static const appLock = '/settings/privacy/app-lock';
  static const appearance = '/settings/appearance';
  static const chatThemeDefault = '/settings/appearance/chat-theme';
  /// Per-chat colour theme picker (`c` = conversation id).
  static String chatThemeFor(String convId) =>
      Uri(path: chatThemeDefault, queryParameters: {'c': convId}).toString();
  static const wallpaperDefault = '/settings/appearance/wallpaper';
  static String wallpaperFor(String convId) =>
      Uri(path: wallpaperDefault, queryParameters: {'c': convId}).toString();
  static const notifications = '/settings/notifications';
  /// Tone picker: `for` = `messages` | `groups` | a conversation id.
  static String tonePicker(String target) =>
      Uri(path: '/settings/notifications/tone', queryParameters: {'for': target})
          .toString();
  static String chatNotifications(String convId) => '/chat/$convId/notifications';
  static const linkedDevices = '/settings/devices';
  static const twoStepPin = '/settings/pin';
  static const changeNumber = '/settings/change-number';
  static const language = '/settings/language';
  static const help = '/settings/help';
  /// PIN gate after sign-in on a new device (auth flow).
  static const pinGate = '/auth/pin';
  static const profile = '/profile';
  static const profileEdit = '/profile/edit';
  static const profileStatus = '/profile/status';
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

/// Re-evaluates redirects whenever AuthStage changes.
Listenable _authListenable(Ref ref) {
  AuthStage key(AuthState s) => s.stage;
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
        path: AppRoutes.pinGate,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const PinGateScreen(),
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
      // `/groups/create` MUST be declared before `/groups/:id` below, which
      // would otherwise swallow "create".
      GoRoute(
        path: AppRoutes.groupsCreate,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const CreateGroupFlowScreen(),
      ),
      // A group is a chat: full screen like `/chat/:id`, no tab bar. Info
      // precedes the bare id so ":id" never swallows "info".
      GoRoute(
        path: '/groups/:id/info',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            GroupInfoScreen(groupId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/groups/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            GroupDetailScreen(groupId: state.pathParameters['id']!),
      ),
      // Invite link landing (deep link `doqto:///g/<token>`): accepts the
      // link, then replaces itself with the group.
      GoRoute(
        path: '/g/:token',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            GroupInviteLinkScreen(token: state.pathParameters['token']!),
      ),
      // Universal-link landings (AASA on api.doqto.ai, docs/compliance.md):
      // a chat or a profile, redirected to the in-app route.
      GoRoute(
        path: '/c/:id',
        parentNavigatorKey: rootNavigatorKey,
        redirect: (_, state) => AppRoutes.chat(state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/u/:userId',
        parentNavigatorKey: rootNavigatorKey,
        redirect: (_, state) => AppRoutes.person(state.pathParameters['userId']!),
      ),
      GoRoute(
        path: AppRoutes.newMessage,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const NewMessageScreen(),
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
              GoRoute(
                path: AppRoutes.networkSuggestions,
                builder: (_, s) => const SuggestionsScreen(),
              ),
            ],
          ),
          // Branch 2 — Groups (M5). A group and its info open full screen above
          // the shell, like a chat.
          StatefulShellBranch(
            navigatorKey: _groupsNavKey,
            routes: [
              GoRoute(
                path: AppRoutes.groups,
                builder: (_, s) => const GroupsTabScreen(),
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
        path: '/chat/:id/media',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            MediaGalleryScreen(conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: AppRoutes.storageManage,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const ManageStorageScreen(),
      ),
      // My Org admin tools (batch 7). The audited read precedes the list so
      // ":rid" never swallows "messages".
      GoRoute(
        path: AppRoutes.myOrgPolicies,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const OrgPoliciesScreen(),
      ),
      GoRoute(
        path: '/my-org/access-requests/:rid/messages',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) =>
            BreakGlassThreadScreen(requestId: state.pathParameters['rid']!),
      ),
      GoRoute(
        path: AppRoutes.myOrgAccessRequests,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const AccessRequestsScreen(),
      ),
      GoRoute(
        path: AppRoutes.myOrgReports,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const OrgReportsScreen(),
      ),
      GoRoute(
        path: AppRoutes.storage,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const StorageScreen(),
      ),
      GoRoute(
        path: '/chat/:id/notifications',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) => CustomNotificationsScreen(
            conversationId: state.pathParameters['id']!),
      ),
      GoRoute(
        path: '/chat/:id',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) => ChatThreadScreen(
          conversationId: state.pathParameters['id']!,
          initialMessageId: state.uri.queryParameters['m'],
        ),
      ),
      GoRoute(
        path: AppRoutes.starred,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, state) => StarredMessagesScreen(
          conversationId: state.uri.queryParameters['c'],
        ),
      ),
      GoRoute(
        path: AppRoutes.settings,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const SettingsScreen(),
      ),
      GoRoute(
        path: AppRoutes.privacy,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const PrivacyScreen(),
      ),
      GoRoute(
        path: AppRoutes.privacyBlocked,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const BlockedListScreen(),
      ),
      // Settings (batch 6).
      GoRoute(
        path: AppRoutes.appLock,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const AppLockScreen(),
      ),
      GoRoute(
        path: AppRoutes.appearance,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const AppearanceScreen(),
      ),
      GoRoute(
        path: AppRoutes.chatThemeDefault,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) =>
            ChatThemePickerScreen(conversationId: s.uri.queryParameters['c']),
      ),
      GoRoute(
        path: AppRoutes.wallpaperDefault,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) =>
            WallpaperPickerScreen(conversationId: s.uri.queryParameters['c']),
      ),
      GoRoute(
        path: AppRoutes.notifications,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const NotificationsScreen(),
      ),
      GoRoute(
        path: '/settings/notifications/tone',
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => TonePickerScreen(target: s.uri.queryParameters['for']),
      ),
      GoRoute(
        path: AppRoutes.linkedDevices,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const LinkedDevicesScreen(),
      ),
      GoRoute(
        path: AppRoutes.twoStepPin,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const TwoStepPinScreen(),
      ),
      GoRoute(
        path: AppRoutes.changeNumber,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const ChangeNumberScreen(),
      ),
      GoRoute(
        path: AppRoutes.language,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const LanguageScreen(),
      ),
      GoRoute(
        path: AppRoutes.help,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const HelpScreen(),
      ),
      GoRoute(
        path: AppRoutes.profileStatus,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) => const StatusScreen(),
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
      GoRoute(
        path: AppRoutes.invite,
        parentNavigatorKey: rootNavigatorKey,
        builder: (_, s) =>
            InviteScreen(initialQuery: s.uri.queryParameters['q'] ?? ''),
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
        AppRoutes.pinGate,
      ].contains(loc);
      final inOrgFlow = [
        AppRoutes.orgSelection,
        AppRoutes.createOrg,
        AppRoutes.joinOrg,
        AppRoutes.pending,
      ].contains(loc);
      if (auth.stage == AuthStage.signedOut &&
          (!inAuthFlow || loc == AppRoutes.registration || loc == AppRoutes.pinGate)) {
        // Your details is the second half of sign-up: it needs the session a
        // verified phone (or, later, social sign-in) creates.
        return AppRoutes.login;
      }
      // Two-step PIN owed on this device (batch 6): nothing else works until
      // it is entered, so park every location on the gate.
      if (auth.stage == AuthStage.pinRequired && loc != AppRoutes.pinGate) {
        return AppRoutes.pinGate;
      }
      if (auth.stage == AuthStage.needsRegistration && loc != AppRoutes.registration) {
        return AppRoutes.registration;
      }
      if (auth.stage == AuthStage.needsOrg && !inOrgFlow) {
        return AppRoutes.orgSelection;
      }
      if (auth.stage == AuthStage.pendingVerification && loc != AppRoutes.pending) {
        return AppRoutes.pending;
      }
      // Signed-in user shouldn't be stuck on the pending screen or any of the
      // pre-auth / onboarding flows. Push them to chats. Creating or joining
      // an org is something a signed-in doctor does from My Org, so those
      // two stay open.
      final orgAction = loc == AppRoutes.createOrg || loc == AppRoutes.joinOrg;
      if (auth.stage == AuthStage.signedIn &&
          (inAuthFlow || (inOrgFlow && !orgAction))) {
        return AppRoutes.chats;
      }
      return null;
    },
  );
});
