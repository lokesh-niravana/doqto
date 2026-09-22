/// UI strings. No inline copy in widgets — every user-facing string lives here.
/// When i18n is on the roadmap, this migrates to ARB + intl without touching widgets.
class Strings {
  Strings._();

  // Brand
  static const String appName = 'Doqto';
  static const String tagline = 'Secure doctor-to-doctor communication';

  // Auth
  static const String authPhoneTitle = 'Enter your phone';
  static const String authPhoneHint = '+1 555 555 0100';
  static const String authSendOtp = 'Send code';
  static const String authOtpTitle = 'Enter verification code';
  static const String authOtpHint = '000000';
  static const String authVerify = 'Verify';
  static const String authResend = 'Resend code';

  // Login — one screen, four ways in
  static const String loginTabPhone = 'Phone';
  static const String loginTabEmail = 'Username / Email';
  static const String loginPhoneHelper = 'Tap the flag to change country';
  static const String loginIdentifier = 'Username / Email';
  static const String loginIdentifierHint = 'you@hospital.org or username';
  static const String loginPassword = 'Password';
  static const String loginPasswordHint = 'Your password';
  static const String loginForgotPassword = 'Forgot password?';
  static const String loginSignIn = 'Sign in';
  static const String loginDividerOr = 'or continue with';
  static const String loginGoogle = 'Continue with Google';
  static const String loginFacebook = 'Continue with Facebook';
  static const String loginApple = 'Continue with Apple';
  static const String loginComingSoon =
      'This sign-in method is coming soon. Use your phone number for now.';

  // Registration
  static const String regFirstName = 'First name';
  static const String regLastName = 'Last name';
  static const String regSpecialty = 'Specialty';
  static const String regNpi = 'NPI number';
  static const String regSpecialtyOther = 'Your specialty';
  static const String regSpecialtyOtherHint = 'Type your specialty';
  static const String regNpiAmbiguous =
      'Several clinicians share that name. Enter your NPI and we\'ll fill in the rest.';
  static const String regMatchTitle = 'Found on the NPI registry';
  static const String regPhone = 'Phone number';
  static const String regPhoneSendCode = 'Send code';
  static const String regPhoneCode = 'Verification code';
  static const String regPhoneVerified = 'Phone number verified';
  static const String regPhoneUnverified =
      'Verify this number, or clear it to skip.';
  static const String regMatchDismiss = 'Not me';
  static const String regMatchUse = 'Use these details';
  static const String regContinue = 'Continue';
  static String regSignedInAs(String who) => 'Signed in as $who';
  static const String regSignOut = 'Not you? Sign out';

  // Plans (shown once, straight after registration)
  static const String planTitle = 'Choose your plan';
  static const String planSubtitle =
      'Full access to secure messaging, groups and your network.';
  static const String planMonthly = 'Monthly';
  static const String planMonthlyPrice = '\$29/mo';
  static const String planYearly = 'Yearly';
  static const String planYearlyPrice = '\$290/yr';
  static const String planYearlyNote = '2 months free';
  static const String planContinue = 'Continue';
  static const String planSkip = 'Skip for now';

  // Org
  static const String orgNoneTitle = 'You\'re not in an organization yet';
  static const String orgNoneBody =
      'Organizations connect you with colleagues at your hospital or practice, '
      'and turn on live updates for your chats.';
  static const String orgNoneCreate = 'Create an organization';
  static const String orgNoneJoin = 'Join with an invite code';
  static const String orgSelectTitle = 'Get started';
  static const String orgCreateTitle = 'Create Organization';
  static const String orgCreateSub = 'Set up your hospital or practice';
  static const String orgJoinTitle = 'Join with Invite Code';
  static const String orgJoinSub = 'Your org admin shared a code with you';
  static const String orgInviteCodeLabel = 'Your org invite code';
  static const String orgPendingTitle = 'Verification in Progress';
  static const String orgPendingBody =
      'We are verifying your organization. You will be notified once approved.';

  // Tabs
  static const String tabChats = 'Chats';
  static const String tabDoctors = 'Doctors';
  static const String tabMyOrg = 'My Org';

  // Chat
  static const String chatMessageHint = 'Message...';
  static const String chatRecording = 'Recording...';
  static const String chatRecordingInstruction = 'Release to send · Slide left to cancel';
  static const String chatMessageDeleted = 'This message was deleted';
  static const String chatEdited = 'Edited';
  static const String chatEditMessage = 'Edit message';
  static const String chatDeleteMessage = 'Delete message';
  static const String chatEditingMessage = 'Editing message';
  static const String chatEditHistory = 'Edit history';
  static const String chatEditHistoryEmpty = 'No earlier versions.';
  static const String chatDeleteForMe = 'Delete for me';
  static const String chatDeleteForEveryone = 'Delete for everyone';
  static String chatDeleteTitle(int n) => n == 1 ? 'Delete message?' : 'Delete $n messages?';

  // Group
  static const String groupNewTitle = 'New Group';
  static const String groupNameHint = 'e.g. ICU Consult Team';
  static const String groupAddMembers = 'ADD MEMBERS';
  static const String groupSelected = 'SELECTED';
  static const String groupInfoTitle = 'Group Info';
  static const String groupLeave = 'Leave Group';
  static const String groupAddMembersBtn = '+ Add Members';

  // Networking (spec §18 copy deck — M0; screens wire these in M1–M5.
  // Legacy inline literals elsewhere are tracked debt, not retrofitted here.)
  // -- Connection buttons / states
  static const String netConnect = 'Connect';
  static const String netPending = 'Pending';
  static const String netConnected = 'Connected';
  static const String netMessage = 'Message';
  static const String netSendMessageRequest = 'Send message request';
  static const String netAccept = 'Accept';
  static const String netDecline = 'Decline';
  static const String netDelete = 'Delete';
  static const String netIgnore = 'Ignore';
  static const String netWithdraw = 'Withdraw';
  static const String netRemoveConnection = 'Remove connection';
  static const String netBlock = 'Block';
  static const String netUnblock = 'Unblock';
  static const String netReport = 'Report';
  // -- Labels
  static const String netTabNetwork = 'Network';
  static const String netTabGroups = 'Groups';
  static const String netConnectedNotificationTitle = 'You are now connected';
  static String netConnectedNotificationBody(String name) =>
      '$name accepted your connection request';
  static const String netConnectedNotificationBodyGeneric =
      'Your connection request was accepted';
  static const String netRequestAcceptedNotificationTitle = 'Request accepted';
  static String netRequestAcceptedNotificationBody(String name) =>
      '$name accepted your message request';
  static const String netRequestAcceptedNotificationBodyGeneric =
      'Your message request was accepted';
  static const String netRequestNotificationTitle = 'Message request';
  static String netRequestNotificationBody(String name) =>
      '$name sent you a message request';
  static const String netRequestNotificationBodyGeneric =
      'You have a new message request';
  static const String netInvitationNotificationTitle = 'Connection request';
  static String netInvitationNotificationBody(String name) =>
      '$name sent you a connection request';
  static const String netInvitationNotificationBodyGeneric =
      'Someone sent you a connection request';
  static const String netInvitations = 'Invitations';
  static const String netConnections = 'Connections';
  static const String netMutualConnections = 'Mutual connections';
  static const String netMyNetwork = 'My Network';
  static const String netReceived = 'Received';
  static const String netSent = 'Sent';
  static const String netManageAll = 'Manage all';
  static const String netDiscoverPeople = 'Discover people';
  static const String netViewProfile = 'View profile';
  static const String netSearchPeopleHint = 'Search doctors by name…';
  static const String netSearchConnectionsHint = 'Search your connections…';
  static const String netYourConnections = 'Your connections';
  static String netSeeAllInvitations(int n) =>
      'See all $n invitation${n == 1 ? '' : 's'}';
  static const String netDegreeFirst = '1st';
  static const String netDegreeSecond = '2nd';
  static const String netDegreeGroup = 'Group';
  static const String netFilterFocused = 'Focused';
  static const String netFilterRequests = 'Requests';
  // -- Reason lines (why you can / can't reach someone)
  static const String netReasonSameOrg = 'You work in the same organization';
  static const String netReasonConnected = 'You are connected';
  static const String netReasonSharedGroup = 'You share a group';
  static const String netReasonRequestNeeded =
      'Not connected — your first message is sent as a request';
  static const String netReasonUnavailable = 'This user is unavailable';
  // -- Message requests
  static const String netRequestBannerSender =
      'Request sent. You can send more messages once they accept.';
  static const String netRequestBannerRecipient =
      'This is a message request. They can\'t see your activity until you accept.';
  static const String netRequestAcceptedToast = 'Request accepted';
  static const String netRequestDeclinedToast = 'Request declined';
  static const String netRequestHint =
      'One short text message, no links or attachments, until they accept.';
  // -- Request-tier composer (M4)
  static const String netRequestWaiting =
      'Waiting for them to accept your message request.';
  static const String netRequestFirstHint =
      'They\'ll get this as a message request. You can send one message until they accept.';
  static const String netRequestDeclinedTerminal =
      'This message request was declined.';
  static const String netHiddenRequests = 'Hidden requests';
  static String netNotConnectedWith(String name) =>
      'You\'re not connected with $name.';
  // -- Toasts
  static const String netInviteSentToast = 'Invitation sent';
  static const String netInviteWithdrawnToast = 'Invitation withdrawn';
  static const String netNowConnectedToast = 'You are now connected';
  static const String netConnectionRemovedToast = 'Connection removed';
  static const String netBlockedToast = 'Blocked';
  static const String netUnblockedToast = 'Unblocked';
  static const String netReportedToast = 'Report submitted';
  // -- Confirmations
  static const String netRemoveConnectionConfirm =
      'Remove this connection? They will not be notified.';
  static const String netBlockConfirm =
      'Block this person? You will no longer see each other or exchange messages.';
  static const String netWithdrawConfirm =
      'Withdraw this invitation? You can send a new one in a few days.';
  static const String netLeaveGroupConfirm = 'Leave this group?';
  // -- Empty states
  static const String netEmptyInvitations = 'No pending invitations';
  static const String netEmptyConnections =
      'No connections yet. Search for colleagues to get started.';
  static const String netEmptySearch = 'No people found. Try a different name.';
  static const String netEmptyNetwork =
      'Grow your network. Search for colleagues to connect.';
  static const String netEmptySent = 'No pending sent invitations';
  static const String netEmptyRequests = 'No message requests';
  static const String netEmptyGroups =
      'No groups yet. Create one to collaborate across organizations.';
  static const String netGroupsComingTitle = 'Groups are coming';
  static const String netGroupsComingBody =
      'Cross-organization groups will live here soon.';
  // -- Groups
  static const String groupJoin = 'Join';
  static const String groupRequestToJoin = 'Request to join';
  static const String groupRequested = 'Requested';
  static const String groupInvited = 'Invited';
  static const String groupMembersLabel = 'Members';
  static const String groupAboutLabel = 'About';
  static const String groupJoinedToast = 'You joined the group';
  static const String groupLeftToast = 'You left the group';
  // -- Groups tab (M5)
  static const String groupsMyGroups = 'My groups';
  static const String groupsDiscover = 'Discover';
  static const String groupsCreate = 'Create group';
  static const String groupsChatLabel = 'Chat';
  static const String groupsOpenChat = 'Open chat';
  static const String groupsView = 'View';
  static const String groupsAdmins = 'Admins';
  static const String groupsInviteOnlyCaption =
      'This group is invite only. You need an invitation to join.';
  static const String groupsWithdrawRequest = 'Withdraw request';
  static const String groupsWithdrawConfirm = 'Withdraw your join request?';
  static const String groupsSearchHint = 'Search groups by name…';
  static const String groupsNoRequests = 'No pending join requests';
  static const String groupsNoMembers = 'No members yet';
  static const String groupsNoDiscover = 'No groups found. Try a different name.';
  static const String groupsCreatedLabel = 'Created';
  static const String groupsRulesLabel = 'Rules';
  static const String groupsMemberMessagingLabel = 'Member messaging';
  static const String groupsAdminOnly = 'Admins only';
  static const String groupsPolicyOpen = 'Anyone can join instantly.';
  static const String groupsPolicyRequest = 'People request to join; admins approve.';
  static const String groupsPolicyInviteOnly = 'People join by invitation only.';
  static const String groupsVisPublic = 'Anyone can find and see this group.';
  static const String groupsVisPrivate =
      'Anyone can find it, but only members see who\'s in it.';
  static const String groupsVisSecret = 'Only members can find this group.';
  static const String groupsDmOpen = 'Members can message each other directly.';
  static const String groupsDmRequest =
      'Members can send each other message requests.';
  static const String groupsDmDisabled =
      'Members cannot message each other from this group.';
  static const String groupsApprove = 'Approve';
  static const String groupsReject = 'Reject';
  // -- Create-group flow (M5)
  static const String groupsStepIdentity = 'Identity';
  static const String groupsStepAccess = 'Access';
  static const String groupsStepInvite = 'Invite';
  static const String groupsNameLabel = 'Group name';
  static const String groupsDescriptionLabel = 'Description';
  static const String groupsDescriptionHint =
      'What is this group about? (optional)';
  static const String groupsVisibilityLabel = 'Who can find this group?';
  static const String groupsJoinPolicyLabel = 'How do people join?';
  static const String groupsInviteStepTitle = 'Invite colleagues';
  static const String groupsInviteSearchHint = 'Search by name or specialty…';
  static const String groupsNoInvitablePeople =
      'No colleagues or connections yet. You can invite people later from the group.';
  static const String groupsInviteStepBody =
      'Invite connections now, or share a link after the group is created.';
  static const String groupsCopyLink = 'Copy invite link';
  static const String groupsLinkCopiedToast = 'Invite link copied';
  static const String groupsCreateCta = 'Create group';
  static const String groupsNext = 'Next';
  static const String groupsBack = 'Back';
  // -- Inline explanations
  static const String netExplainRequestTier =
      'Messages from people outside your network arrive as requests.';
  static const String netExplainDegree =
      '1st: connected · 2nd: connection of a connection';
  static const String netExplainOrgPolicy =
      'Your organization has turned off external networking.';
  // -- Errors
  static const String netErrorGeneric = 'Something went wrong. Try again.';
  static const String netErrorQuota =
      'You\'ve reached your invitation limit for now. Try again later.';
  static const String netErrorCooldown =
      'You can\'t send another invitation to this person yet.';
  static const String netErrorUserUnavailable = 'This user is unavailable.';
  static const String netErrorRequestClosed =
      'You can\'t reply until your request is accepted.';

  // Profile sections
  static const String profileAbout = 'About';
  static const String profileExperience = 'Experience';
  static const String profileSkills = 'Skills';

  // Common
  static const String copy = 'Copy';
  static const String cancel = 'Cancel';
  static const String save = 'Save';
  static const String retry = 'Retry';
  static const String loading = 'Loading...';
}
