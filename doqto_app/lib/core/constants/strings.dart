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
  static const String loginPhoneHelper = 'Tap the flag to change country';
  static const String loginDividerOr = 'or continue with';
  static const String loginGoogle = 'Continue with Google';
  static const String loginFacebook = 'Continue with Facebook';
  static const String loginApple = 'Continue with Apple';

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
  static const String regPhoneVerify = 'Verify';
  static const String regPhoneVerified = 'Phone number verified';
  static const String regPhoneUnverified =
      'Verify this number, or clear it to skip.';
  static const String regMatchDismiss = 'Not me';
  static const String regMatchUse = 'Use these details';
  static const String regContinue = 'Continue';
  static String regSignedInAs(String who) => 'Signed in as $who';
  static const String regSignOut = 'Not you? Sign out';
  static const String regApplePrivateEmail = 'your Apple ID (email hidden)';

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
  // -- Invite a colleague
  static const String inviteTitle = 'Invite a colleague';
  static const String inviteSettingsSubtitle = 'Find a doctor by name or NPI';
  static const String inviteSearchHint = 'Name or NPI';
  static const String inviteAnyState = 'Any';
  static const String inviteStateLabel = 'State';
  static const String inviteButton = 'Invite';
  static const String inviteRequested = 'Requested';
  static const String inviteOnDoqto = 'On Doqto';
  static const String inviteIntro =
      'Search the NPI Registry. Colleagues already on Doqto show Connect or Message.';
  static const String inviteNoResults =
      'No match yet. Add a first name or pick a state: common last names need one.';
  static String inviteResultCount(int n) =>
      '$n ${n == 1 ? 'doctor' : 'doctors'} in the NPI Registry';
  static const String inviteCantFind = "Can't find them?";
  static const String inviteCantFindBody =
      'Residents, doctors outside the US, or anyone else: send them the app link directly.';
  static const String inviteShareLink = 'Share invite link';
  static const String inviteLink = 'https://doqto.ai/get';
  static String inviteMessage(String? greeting) =>
      "${greeting == null ? '' : '$greeting, '}I'm on Doqto, secure messaging for doctors. "
      "Join me and let's message there: $inviteLink";
  static String inviteFromSearch(String q) => 'Invite "$q"';
  static String inviteNobodyNamed(String q) => 'No one named "$q" on Doqto yet';
  static const String inviteNobodyBody =
      'Look them up in the NPI Registry and send them an invite.';
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
  static const String groupYou = 'You';
  static String groupMemberCount(int n) => n == 1 ? '1 member' : '$n members';
  static const String groupAboutLabel = 'About';
  static const String groupJoinedToast = 'You joined the group';
  static const String groupLeftToast = 'You left the group';
  // -- Groups tab (M5)
  static const String groupsMyGroups = 'My groups';
  static const String groupsDiscover = 'Discover';
  static const String groupsCreate = 'Create group';
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
  static const String groupMembersAfterJoin =
      'You can see who is in this group once you join.';
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
  // -- Group management (batch 1)
  static const String groupAccept = 'Accept';
  static const String groupDecline = 'Decline';
  static const String groupInvitedBy = 'You\'ve been invited to this group';
  static const String groupDeclinedToast = 'Invite declined';
  static const String groupEditName = 'Group name';
  static const String groupEditDescription = 'Description';
  static const String groupAddDescription = 'Add a description';
  static const String groupChangePhoto = 'Change group photo';
  static const String groupRemovePhoto = 'Remove photo';
  static const String groupAddMembersTitle = 'Add members';
  static const String groupInviteSent = 'Invite sent';
  static String groupInvitesSent(int n) =>
      n == 1 ? '1 invite sent' : '$n invites sent';
  static const String groupNoOneToAdd =
      'Everyone you can invite is already here. Share an invite link instead.';
  static const String groupMemberMessage = 'Message';
  static const String groupMemberViewProfile = 'View profile';
  static const String groupMemberPromote = 'Make admin';
  static const String groupMemberDemote = 'Remove as admin';
  static const String groupMemberRemove = 'Remove from group';
  static const String groupMemberBan = 'Ban from group';
  static const String groupMemberTransfer = 'Transfer ownership';
  static String groupRemoveConfirm(String name) => 'Remove $name from the group?';
  static String groupBanConfirm(String name) =>
      'Ban $name? They won\'t be able to rejoin, even by invite.';
  static String groupTransferConfirm(String name) =>
      'Make $name the owner? You\'ll become an admin.';
  static const String groupSettingsLabel = 'Group settings';
  static const String groupSendMessagesLabel = 'Send messages';
  static const String groupSendAll = 'All members';
  static const String groupSendAdmins = 'Admins only';
  static const String groupDmLabel = 'Member direct messages';
  static const String groupDmOpenShort = 'Open';
  static const String groupDmRequestShort = 'Connections only';
  static const String groupDmDisabledShort = 'Off';
  static const String groupDisappearingLabel = 'Disappearing messages';
  static const String groupAdminsOnlyNotice = 'Only admins can send messages';
  static const String groupInviteLinksLabel = 'Invite links';
  static const String groupCreateLink = 'Create invite link';
  static const String groupLinkMaxUses = 'Max uses';
  static const String groupLinkMaxUsesHint = 'Unlimited';
  static const String groupLinkExpires = 'Expires';
  static const String groupLinkExpiry1Day = '1 day';
  static const String groupLinkExpiry7Days = '7 days';
  static const String groupLinkExpiryNever = 'Never';
  static const String groupLinkShare = 'Share';
  static const String groupLinkCopy = 'Copy';
  static const String groupLinkRevoke = 'Revoke';
  static const String groupLinkRevoked = 'Invite link revoked';
  static const String groupLinkNone = 'No active invite links';
  static const String groupPendingInvitesLabel = 'Pending invites';
  static const String groupInviteCancel = 'Cancel invite';
  static const String groupPhotoAdjustTitle = 'Adjust group photo';
  static const String groupInviteCancelled = 'Invite cancelled';
  static const String groupInviteAwaiting = 'Waiting for them to accept';
  static String groupInvitedAgo(String when) => 'Invited $when';
  static const String groupJoinedViaLink = 'You joined the group';
  static const String groupJoiningViaLink = 'Joining group…';
  static const String groupMessageInfo = 'Message info';
  static const String groupReadBy = 'Read by';
  static const String groupDeliveredTo = 'Delivered to';
  static const String groupNotYetDelivered = 'Not yet delivered';
  static const String groupInviteNotificationTitle = 'Group invite';
  static String groupInviteNotificationBody(String name, String group) =>
      '$name invited you to $group';
  static const String groupInviteNotificationBodyGeneric =
      'You\'ve been invited to a group';
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

  // Privacy screen (batch 2)
  static const String privacyTitle = 'Privacy';
  static const String privacySettingsSubtitle =
      'Last seen, read receipts, blocked contacts';
  static const String privacyWhoCanSee = 'Who can see my';
  static const String privacyLastSeen = 'Last seen';
  static const String privacyOnline = 'Online';
  static const String privacyProfilePhoto = 'Profile photo';
  static const String privacyAbout = 'About';
  static const String privacyMessaging = 'Messaging';
  static const String privacyReadReceipts = 'Read receipts';
  static const String privacyReadReceiptsHint =
      "If turned off, you won't send or receive read receipts in direct "
      'chats. Groups always show read-by.';
  static const String privacyDefaultTimer = 'Default message timer';
  static const String privacyDefaultTimerHint =
      'New direct chats you start disappear after this long.';
  static const String privacyLinkPreviews = 'Link previews';
  static const String privacyLinkPreviewsHint =
      'Show a preview card for links you send and receive.';
  static const String privacyNetwork = 'Network';
  static const String privacyInvitePolicy = 'Connection requests';
  static const String privacyDiscoverability = 'Discoverability';
  static const String privacyShowMutuals = 'Show mutual connections';
  static const String privacyShowMutualsHint =
      'Let others see the connections you have in common.';
  static const String privacyBlocked = 'Blocked contacts';
  static const String privacyBlockedEmpty = 'You haven\'t blocked anyone.';
  static const String privacyBlockedHint =
      "Blocked doctors can't message you, see your profile or find you.";
  static const String privacyUnblockConfirmTitle = 'Unblock this doctor?';
  static const String privacyUnblockConfirmBody =
      'They will be able to find you, view your profile and message you '
      'again. You are not reconnected automatically.';
  static const String privacyUnblockedToast = 'Unblocked';
  static const String privacyBlockedBanner = 'You blocked this doctor';
  static const String privacyReciprocalHint =
      "If you don't share your last seen, you won't see others' either.";
  static const String privacyLastSeenEveryone = 'Everyone';
  static const String privacyLastSeenConnections = 'Connections and colleagues';
  static const String privacyLastSeenNobody = 'Nobody';
  static const String privacyOnlineSame = 'Same as last seen';
  static const String privacyOnlineNobody = 'Nobody';
  static const String privacyTimerOff = 'Off';
  static const String privacySaveFailed = "Couldn't save that. Try again.";
  static const String presenceOnline = 'online';

  // Chat list preferences (batch 3)
  static const String chatPin = 'Pin';
  static const String chatUnpin = 'Unpin';
  static const String chatMute = 'Mute';
  static const String chatUnmute = 'Unmute';
  static const String chatMuteTitle = 'Mute notifications';
  static const String chatMuteHint =
      'Messages still arrive; you just won\'t be notified.';
  static const String chatArchive = 'Archive';
  static const String chatUnarchive = 'Unarchive';
  static const String chatMarkUnread = 'Mark as unread';
  static const String chatMarkRead = 'Mark as read';
  static const String chatClear = 'Clear chat';
  static const String chatClearTitle = 'Clear this chat?';
  static const String chatClearBody =
      'Messages are removed from this device and your view only. The other '
      'members keep their copies.';
  static const String chatDeleteChat = 'Delete chat';
  static const String chatDeleteChatTitle = 'Delete this chat?';
  static const String chatDeleteChatBody =
      'The chat leaves your list and its messages are cleared for you. It '
      'comes back if the other person writes again.';
  static const String chatLeaveGroupTitle = 'Leave this group?';
  static const String chatLeaveGroupBody =
      'You\'ll stop receiving its messages. An admin can invite you back.';
  static const String chatLeave = 'Leave';
  static const String chatMore = 'More';
  static String chatArchivedRow(int n) => 'Archived ($n)';
  static const String chatArchivedEmpty = 'No archived chats';
  static const String chatArchivedEmptyHint =
      'Swipe a chat left to archive it.';
  static const String chatUnreadEmpty = 'You\'re all caught up';
  static const String chatUnreadEmptyHint = 'No unread chats right now.';
  static const String chatGroupsEmpty = 'No group chats yet';
  static const String chatGroupsEmptyHint =
      'Create a group from the Groups tab.';
  static const String chatDraftPrefix = 'Draft: ';
  static const String chatPinnedToast = 'Pinned';
  static const String chatUnpinnedToast = 'Unpinned';
  static const String chatArchivedToast = 'Archived';
  static const String chatUnarchivedToast = 'Unarchived';
  static const String chatMutedToast = 'Muted';
  static const String chatUnmutedToast = 'Unmuted';
  static const String chatClearedToast = 'Chat cleared';
  static const String chatDeletedToast = 'Chat deleted';
  // Message features (batch 4)
  static const String chatReply = 'Reply';
  static const String chatForward = 'Forward';
  static const String chatCopy = 'Copy';
  static const String chatCopied = 'Copied';
  static const String chatStar = 'Star';
  static const String chatUnstar = 'Unstar';
  static const String chatPinMessage = 'Pin';
  static const String chatUnpinMessage = 'Unpin';
  static const String chatInfo = 'Info';
  static const String chatEdit = 'Edit';
  static const String chatDelete = 'Delete';
  static const String chatReport = 'Report';
  static const String chatSelect = 'Select';
  static const String chatReplyingTo = 'Replying to';
  static const String chatYou = 'You';
  static const String chatForwarded = 'Forwarded';
  static const String chatForwardedManyTimes = 'Forwarded many times';
  static const String chatForwardTitle = 'Forward to…';
  static const String chatForwardHint = 'Search chats and people';
  static const String chatForwardLimit = 'Up to 5 chats';
  static const String chatForwardedToast = 'Forwarded';
  static const String chatStarredToast = 'Starred';
  static const String chatUnstarredToast = 'Unstarred';
  static const String chatStarredMessages = 'Starred messages';
  static const String chatStarredEmpty = 'No starred messages';
  static const String chatStarredEmptyHint =
      'Long-press a message and tap Star to keep it here.';
  static const String chatPinTitle = 'Pin message';
  static const String chatPinHint = 'Everyone in the chat sees it at the top.';
  static const String chatPinnedMessage = 'Pinned message';
  static const String chatPinnedToastMessage = 'Message pinned';
  static const String chatUnpinnedToastMessage = 'Message unpinned';
  static const String chatOpenLinkTitle = 'Open link?';
  static const String chatOpenLinkBody =
      'This opens outside Doqto. Only open links you trust.';
  static const String chatOpenLink = 'Open';
  static const String chatCallNumberTitle = 'Call this number?';
  static const String chatSearch = 'Search';
  static const String chatSearchHint = 'Search in chat';
  static const String chatSearchNone = 'No matches';
  static const String chatJumpToDate = 'Jump to date';
  static const String chatJumpToDateNone = 'Nothing on or before that day.';
  static String chatUnreadDivider(int n) =>
      n == 1 ? '1 unread message' : '$n unread messages';
  static const String chatReportTitle = 'Report message';
  static const String chatReportHint =
      'The message and the few before it are sent to Doqto for review. The '
      'sender is not told.';
  static const String chatReportDetails = 'Details (optional)';
  static const String chatReportSubmit = 'Send report';
  static const String chatReportedToast = 'Report sent. Thank you.';
  static const String chatAdminRemoved = 'Admin removed a message';
  static const String chatFormatBold = 'Bold';
  static const String chatFormatItalic = 'Italic';
  static const String chatFormatStrike = 'Strikethrough';
  static const String chatFormatMono = 'Monospace';
  static const String chatMentionHint = 'Mention someone';
  static const String settingsKeepArchived = 'Keep chats archived';
  static const String settingsKeepArchivedHint =
      'Archived chats stay archived when a new message arrives.';
  static const String profileMuteNotifications =
      'Mute notifications from this person';
  static const String profileUnmuteNotifications = 'Unmute notifications';
  static const String profileMutedToast = 'Notifications muted';
  static const String profileUnmutedToast = 'Notifications on';

  // Common
  static const String copy = 'Copy';
  static const String cancel = 'Cancel';
  static const String save = 'Save';
  static const String retry = 'Retry';
  static const String loading = 'Loading...';

  // ---- Media (batch 5) ----
  static const String mediaTapToDownload = 'Tap to download';
  static const String mediaCaptionHint = 'Add a caption…';
  static const String mediaPhotos = 'Photos';
  static const String mediaPhoto = 'Photo';
  static const String mediaVideo = 'Video';
  static const String mediaDocument = 'Document';
  static const String mediaScanDocument = 'Scan document';
  static const String mediaTakePhoto = 'Take photo';
  static const String mediaRecordVideo = 'Record video';
  static const String mediaChooseGallery = 'Choose from gallery';
  static const String mediaPoll = 'Poll';
  static const String mediaShare = 'Share';
  static const String mediaSaveToPhotos = 'Save to Photos';
  static const String mediaSaved = 'Saved to Photos';
  static const String mediaSaveFailed = 'Could not save';
  static const String mediaForward = 'Forward';
  static const String mediaDeleteForMe = 'Delete for me';
  static const String mediaStar = 'Star';
  static const String mediaExportBlocked = 'Saving and sharing is turned off for this chat';
  static const String mediaGalleryTitle = 'Media, links and docs';
  static const String mediaTabMedia = 'Media';
  static const String mediaTabDocs = 'Docs';
  static const String mediaTabLinks = 'Links';
  static const String mediaGalleryEmptyMedia = 'No photos or videos yet';
  static const String mediaGalleryEmptyDocs = 'No documents yet';
  static const String mediaGalleryEmptyLinks = 'No links yet';
  static const String mediaTooManyPhotos = 'You can send up to 30 photos at once';
  static const String mediaVideoTooLong = 'Videos can be up to 10 minutes';
  static const String mediaVideoTooLarge = 'Videos can be up to 100 MB';
  static const String mediaFileTooLarge = 'Files can be up to 100 MB';
  static const String mediaScanUnavailable = 'Scanning is not available on this device';
  static const String voiceTooShort = 'Hold to record';
  static const String voiceSlideToCancel = 'Slide to cancel';
  static const String voiceLocked = 'Recording';
  static const String voiceSend = 'Send';
  static const String voiceCancel = 'Cancel';
  static const String pollCreateTitle = 'New poll';
  static const String pollQuestion = 'Question';
  static const String pollQuestionHint = 'Ask a question';
  static const String pollOptions = 'Options';
  static const String pollOptionHint = 'Add option';
  static const String pollAllowMultiple = 'Allow multiple answers';
  static const String pollAddOption = 'Add option';
  static const String pollSend = 'Send poll';
  static const String pollNeedTwo = 'Add at least two options';
  static const String pollNeedQuestion = 'Add a question';
  static const String pollDuplicate = 'Options must be different';
  static const String pollSelectOne = 'Select one';
  static const String pollSelectMany = 'Select one or more';
  static const String pollViewVotes = 'View votes';
  static const String pollNoVotes = 'No votes yet';
  static const String pollVotes = 'votes';
  static const String pollVote = 'vote';
  static const String storageTitle = 'Storage and data';
  static const String storageUploadQuality = 'Upload quality';
  static const String storageUploadQualityHint = 'Photos are resized before sending';
  static const String storageAutoDownload = 'Media auto-download';
  static const String storageAutoDownloadHint = 'Choose when photos, voice notes, videos and documents download by themselves';
  static const String storageManage = 'Manage storage';
  static const String storageNetworkUsage = 'Network usage';
  static const String storageSent = 'Sent';
  static const String storageReceived = 'Received';
  static const String storageResetUsage = 'Reset statistics';
  static const String storageClearAll = 'Clear all media';
  static const String storageClearChat = 'Clear';
  static const String storageEmpty = 'No downloaded media';
  static const String storageTotal = 'Total';
  static const String storageWifi = 'Wi-Fi';
  static const String storageCellular = 'Cellular';
  static const String storageNever = 'Never';
  static const String storageWifiOnly = 'Wi-Fi only';
  static const String storageWifiAndCellular = 'Wi-Fi and cellular';

  // Compliance (batch 7): My Org → Policies / Access requests / Reports
  static const String myOrgAdminSection = 'Administration';
  static const String myOrgPolicies = 'Policies';
  static const String myOrgPoliciesHint = 'Copy, export, screenshots, retention, legal hold';
  static const String myOrgAccessRequests = 'Access requests';
  static const String myOrgAccessRequestsHint = 'Emergency access to a conversation, approved by a second admin';
  static const String myOrgReports = 'Reports';
  static const String myOrgReportsHint = 'Reports about or by members of this organisation';
  static const String myOrgMemberPolicies = 'Your organisation\'s policies';
  static const String myOrgMemberPoliciesHint = 'What your admins allow in organisation chats';

  static const String orgPoliciesTitle = 'Policies';
  static const String orgPoliciesReadOnlyFooter = 'Set by your organisation\'s admins. Ask them to change anything here.';
  static const String orgPoliciesSectionContent = 'Content';
  static const String orgPoliciesSectionNotifications = 'Notifications';
  static const String orgPoliciesSectionRetention = 'Retention';
  static const String orgPolicyForwardOutside = 'Forward outside the organisation';
  static const String orgPolicyForwardOutsideHint = 'Members can forward messages to chats outside this organisation';
  static const String orgPolicyAllowCopy = 'Copy message text';
  static const String orgPolicyAllowCopyHint = 'Show Copy on messages in organisation chats';
  static const String orgPolicyMediaExport = 'Save and share media';
  static const String orgPolicyMediaExportHint = 'Save to Photos and Share on photos, videos and documents';
  static const String orgPolicyBlockScreenshots = 'Block screenshots';
  static const String orgPolicyBlockScreenshotsHint = 'Android blanks organisation chats in screenshots; iOS screenshots are audited';
  static const String orgPolicyPreviewDefault = 'Message previews in banners';
  static const String orgPolicyPreviewDefaultHint = 'Members who have not chosen see message text in notifications';
  static const String orgPolicyDefaultDisappear = 'Default disappearing timer';
  static const String orgPolicyDefaultDisappearHint = 'New organisation group chats start with this timer';
  static const String orgPolicyRetention = 'Keep messages for';
  static const String orgPolicyRetentionHint = 'Older messages in organisation chats are removed automatically';
  static const String orgPolicyRetentionForever = 'Forever';
  static String orgPolicyRetentionDays(int days) => days == 1 ? '1 day' : '$days days';
  static const String orgPolicyLegalHold = 'Legal hold';
  static const String orgPolicyLegalHoldHint = 'Nothing in organisation chats is destroyed, including deleted messages, until the hold is lifted';
  static const String orgPolicyLegalHoldOnTitle = 'Turn on legal hold?';
  static const String orgPolicyLegalHoldOnBody =
      'Deleted messages, expired messages and deleted accounts keep their content for this organisation\'s chats until you lift the hold. Members still see deletions as usual. Content is readable only through an approved access request.';
  static const String orgPolicyLegalHoldOffTitle = 'Lift legal hold?';
  static const String orgPolicyLegalHoldOffBody =
      'Everything held back will be destroyed on the next purge pass — deleted messages, expired messages and deleted accounts. This cannot be undone.';
  static const String orgPolicyRetentionTitle = 'Change retention?';
  static String orgPolicyRetentionBody(String keep) =>
      'Messages in this organisation\'s chats older than $keep will be removed for everyone on the next pass. This cannot be undone.';
  static const String orgPolicyConfirm = 'Confirm';
  static const String orgPoliciesSaveFailed = 'Could not save that policy';
  static const String policyOn = 'On';
  static const String policyOff = 'Off';

  static const String accessRequestsTitle = 'Access requests';
  static const String accessRequestsEmpty = 'No access requests';
  static const String accessRequestsEmptyHint =
      'Emergency access to a conversation needs a written reason and a second admin\'s approval. Every read is audited and the members are told.';
  static const String accessRequestNew = 'Request access';
  static const String accessRequestConversation = 'Conversation';
  static const String accessRequestConversationHint = 'Conversation ID';
  static const String accessRequestPickConversation = 'Choose from my chats';
  static const String accessRequestReason = 'Reason';
  static const String accessRequestReasonHint = 'Why you need to read this conversation';
  static const String accessRequestReasonRequired = 'A reason is required';
  static const String accessRequestConversationRequired = 'Choose or paste a conversation';
  static const String accessRequestSubmit = 'Send request';
  static const String accessRequestCreated = 'Request sent. Another admin must approve it.';
  static const String accessRequestApprove = 'Approve';
  static const String accessRequestReject = 'Reject';
  static const String accessRequestOpen = 'Open audited view';
  static const String accessRequestStatusPending = 'Pending';
  static const String accessRequestStatusApproved = 'Approved';
  static const String accessRequestStatusRejected = 'Rejected';
  static const String accessRequestStatusExpired = 'Expired';
  static String accessRequestRequestedBy(String who) => 'Requested by $who';
  static const String accessRequestYou = 'you';
  static String accessRequestAccessUntil(String when) => 'Access until $when';
  static const String accessRequestAwaitingOther = 'Waiting for another admin to decide';
  static const String accessRequestDecisionFailed = 'Could not record that decision';
  static const String accessRequestApproveTitle = 'Approve access?';
  static String accessRequestApproveBody(String who) =>
      '$who will be able to read this conversation for 24 hours. Every page they open is audited and the members are told an administrator accessed it.';
  static const String breakGlassTitle = 'Audited view';
  static const String breakGlassBanner = 'Compliance access — audited; the members were told';
  static const String breakGlassEmpty = 'No messages in this conversation';
  static const String breakGlassOlder = 'Load older messages';
  static const String breakGlassDeleted = 'Deleted by the sender — content kept under legal hold';
  static const String breakGlassSystem = 'System message';

  static const String orgReportsTitle = 'Reports';
  static const String orgReportsEmpty = 'No reports';
  static const String orgReportsEmptyHint =
      'Reports about members of this organisation, or filed by them, appear here. Message content is never shown.';
  static const String orgReportsFilterAll = 'All';
  static const String orgReportStatusOpen = 'Open';
  static const String orgReportStatusReviewing = 'Reviewing';
  static const String orgReportStatusActioned = 'Actioned';
  static const String orgReportStatusDismissed = 'Dismissed';
  static const String orgReportSubjectUser = 'About a member';
  static const String orgReportSubjectMessage = 'About a message';
  static String orgReportContext(int n) => n == 1 ? '1 message attached' : '$n messages attached';
  static const String orgReportChangeStatus = 'Change status';
  static const String orgReportStatusFailed = 'Could not update the report';

  static const String scheduledTitle = 'Scheduled messages';
  static const String scheduledEmpty = 'Nothing scheduled in this chat';
  static const String scheduledEmptyHint = 'Hold the send button to schedule a message.';
  static const String scheduledCancel = 'Cancel';
  static const String scheduledCancelled = 'Scheduled message cancelled';
  static const String scheduledCancelFailed = 'Could not cancel that message';
  static const String scheduledFailed = 'Failed to send';
  static const String scheduledPending = 'Will be sent';

  static const String deviceModifiedBanner =
      'This device appears modified; your organisation may block access';

  // Image crop (before a photo is saved or sent)
  static const String cropTitle = 'Adjust photo';
  static const String cropDone = 'Done';
  static const String cropCancel = 'Cancel';
  static const String cropReset = 'Reset';
  static const String cropAspectFree = 'Free';
  static const String cropFailed = "Couldn't crop that photo";
  static const String captionCrop = 'Crop';
}
