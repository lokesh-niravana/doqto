// ignore: unused_import
import 'package:intl/intl.dart' as intl;
import 'app_localizations.dart';

// ignore_for_file: type=lint

/// The translations for English (`en`).
class AppLocalizationsEn extends AppLocalizations {
  AppLocalizationsEn([String locale = 'en']) : super(locale);

  @override
  String get settingsTitle => 'Settings';

  @override
  String get settingsAccount => 'Account';

  @override
  String get settingsPrivacy => 'Privacy';

  @override
  String get settingsPrivacySubtitle =>
      'Last seen, read receipts, who can reach you';

  @override
  String get settingsAppearance => 'Chats & appearance';

  @override
  String get settingsAppearanceSubtitle =>
      'Theme, chat colour, wallpaper, font size';

  @override
  String get settingsNotifications => 'Notifications';

  @override
  String get settingsNotificationsSubtitle => 'Tones, vibration, previews';

  @override
  String get settingsStorage => 'Storage and data';

  @override
  String get settingsStorageSubtitle => 'Media, downloads and usage';

  @override
  String get settingsLanguage => 'App language';

  @override
  String get settingsHelp => 'Help';

  @override
  String get settingsHelpSubtitle =>
      'Help centre, contact us, terms and privacy';

  @override
  String get settingsStarred => 'Starred messages';

  @override
  String get settingsLinkedDevices => 'Linked devices';

  @override
  String get settingsTwoStep => 'Two-step verification';

  @override
  String get settingsChangeNumber => 'Change number';

  @override
  String get settingsExport => 'Request account info';

  @override
  String get settingsAppLock => 'App lock';

  @override
  String get settingsSignOut => 'Sign out';

  @override
  String get settingsDeleteAccount => 'Delete account';

  @override
  String settingsVersion(String version) {
    return 'Version $version';
  }

  @override
  String get languageSystem => 'System default';

  @override
  String get languageEnglish => 'English';

  @override
  String get languageSpanish => 'Español';

  @override
  String get commonCancel => 'Cancel';

  @override
  String get commonSave => 'Save';

  @override
  String get commonDone => 'Done';

  @override
  String get commonRetry => 'Retry';

  @override
  String get commonOn => 'On';

  @override
  String get commonOff => 'Off';

  @override
  String get commonSaveFailed => 'Couldn\'t save that. Try again.';

  @override
  String get chatsTitle => 'Chats';

  @override
  String get chatsSearchHint => 'Search chats';

  @override
  String get chatsEmptyTitle => 'No conversations yet';

  @override
  String get chatsEmptyBody =>
      'Start a message with a colleague to see it here.';

  @override
  String get chatsArchived => 'Archived';

  @override
  String get chatsDraftPrefix => 'Draft: ';

  @override
  String get threadMessageHint => 'Message';

  @override
  String get threadTyping => 'typing…';

  @override
  String get threadOnline => 'online';

  @override
  String get threadSearch => 'Search in chat';

  @override
  String get threadReply => 'Reply';

  @override
  String get threadForward => 'Forward';

  @override
  String get threadCopy => 'Copy';

  @override
  String get threadDelete => 'Delete';

  @override
  String get threadEdited => 'edited';

  @override
  String get threadMessageDeleted => 'Message deleted';

  @override
  String get appearanceTitle => 'Chats & appearance';

  @override
  String get appearanceDisplay => 'Display';

  @override
  String get appearanceTheme => 'Theme';

  @override
  String get appearanceThemeLight => 'Light';

  @override
  String get appearanceThemeDark => 'Dark';

  @override
  String get appearanceThemeSystem => 'System';

  @override
  String get appearanceFontSize => 'Font size';

  @override
  String get appearanceFontSmall => 'Small';

  @override
  String get appearanceFontMedium => 'Medium';

  @override
  String get appearanceFontLarge => 'Large';

  @override
  String get appearanceFontHint => 'Follows your phone\'s text size too';

  @override
  String get appearancePreview => 'Secure messaging that fits your day.';

  @override
  String get appearanceChatsSection => 'Chats';

  @override
  String get appearanceDefaultChatTheme => 'Default chat colour';

  @override
  String get appearanceDefaultWallpaper => 'Default wallpaper';

  @override
  String get appearanceWallpaperNone => 'None';

  @override
  String get appearanceWallpaperPhoto => 'Your photo';

  @override
  String get appearanceEnterIsSend => 'Enter is send';

  @override
  String get appearanceEnterIsSendHint =>
      'Return key sends instead of adding a line';

  @override
  String get appearanceVoiceTranscript => 'Voice note transcript';

  @override
  String get appearanceVoiceTranscriptHint =>
      'Transcribe voice notes while you record';

  @override
  String get appearanceKeepArchived => 'Keep chats archived';

  @override
  String get appearanceKeepArchivedHint =>
      'Archived chats stay archived when a new message arrives';

  @override
  String get chatThemeTitle => 'Chat colour';

  @override
  String get chatThemeDefault => 'Default';

  @override
  String get chatThemeDefaultHint => 'Uses your default chat colour';

  @override
  String get chatThemeSent => 'Sounds good, see you at 3';

  @override
  String get chatThemeReceived => 'Can we move rounds to 3?';

  @override
  String get chatThemeSaveFailed =>
      'Couldn\'t change the chat colour. Try again.';

  @override
  String get wallpaperTitle => 'Wallpaper';

  @override
  String get wallpaperPatterns => 'Patterns';

  @override
  String get wallpaperSolids => 'Solid colours';

  @override
  String get wallpaperPhoto => 'Choose from photos';

  @override
  String get wallpaperNone => 'None';

  @override
  String get wallpaperDim => 'Dim wallpaper in dark mode';

  @override
  String get wallpaperSaveFailed =>
      'Couldn\'t change the wallpaper. Try again.';

  @override
  String get statusTitle => 'Status';

  @override
  String get statusPresets => 'Presets';

  @override
  String get statusCustom => 'Custom';

  @override
  String get statusCustomHint => 'What should colleagues know?';

  @override
  String get statusClearAfter => 'Clear after';

  @override
  String get statusOneHour => '1 hour';

  @override
  String get statusEightHours => '8 hours';

  @override
  String get statusOneDay => '24 hours';

  @override
  String get statusNever => 'Never';

  @override
  String get statusSave => 'Save status';

  @override
  String get statusClear => 'Clear status';

  @override
  String get statusNone => 'No status';

  @override
  String get statusSaveFailed => 'Couldn\'t update your status. Try again.';

  @override
  String get notifTitle => 'Notifications';

  @override
  String get notifMessages => 'Messages';

  @override
  String get notifGroups => 'Groups';

  @override
  String get notifTone => 'Tone';

  @override
  String get notifVibrate => 'Vibrate';

  @override
  String get notifVibrateDefault => 'Default';

  @override
  String get notifVibrateShort => 'Short';

  @override
  String get notifVibrateLong => 'Long';

  @override
  String get notifVibrateOff => 'Off';

  @override
  String get notifVibrateIosFooter => 'Vibration follows your iPhone settings.';

  @override
  String get notifShowPreview => 'Show preview';

  @override
  String get notifShowPreviewHint => 'Show message text in banners';

  @override
  String get notifHighPriority => 'High priority';

  @override
  String get notifHighPriorityHint => 'Show banners at the top of the screen';

  @override
  String get notifReactions => 'Reactions';

  @override
  String get notifReactionNotifications => 'Reaction notifications';

  @override
  String get notifReactionNotificationsHint =>
      'Notify when someone reacts to your message';

  @override
  String get notifInApp => 'In-app';

  @override
  String get notifConversationTones => 'Conversation tones';

  @override
  String get notifConversationTonesHint =>
      'Play sounds for incoming and outgoing messages';

  @override
  String get notifHaptics => 'Haptics';

  @override
  String get notifHapticsHint => 'Light vibration on new messages';

  @override
  String get notifReset => 'Reset notification settings';

  @override
  String get notifResetTitle => 'Reset notification settings?';

  @override
  String get notifResetBody =>
      'All tones, vibration and preview choices go back to the defaults. Custom notifications for individual chats are kept.';

  @override
  String get notifResetConfirm => 'Reset';

  @override
  String get notifResetDone => 'Notification settings reset';

  @override
  String get toneTitle => 'Tone';

  @override
  String get toneDefault => 'Default';

  @override
  String get toneNone => 'None';

  @override
  String get toneHint => 'Tap a tone to hear it.';

  @override
  String get chatNotifTitle => 'Custom notifications';

  @override
  String get chatNotifUseCustom => 'Use custom notifications';

  @override
  String get chatNotifUseCustomHint =>
      'Pick a tone and vibration for this chat only';

  @override
  String get chatNotifMute => 'Mute notifications';

  @override
  String get chatNotifMuted => 'Muted';

  @override
  String get chatNotifNotMuted => 'Not muted';

  @override
  String get chatNotifUnmute => 'Unmute';

  @override
  String get appLockLockedTitle => 'Doqto is locked';

  @override
  String get appLockLockedBody =>
      'Unlock with Face ID, Touch ID or your passcode.';

  @override
  String get appLockUnlock => 'Unlock';

  @override
  String get appLockUnavailable =>
      'Set up a passcode or biometrics on this phone first.';

  @override
  String get appLockEnableReason => 'Confirm it\'s you to turn on app lock';

  @override
  String get appLockNotVerified => 'Couldn\'t verify — app lock stays off.';

  @override
  String get appLockFooter =>
      'When on, Doqto asks for Face ID, Touch ID or your passcode when you come back to it. You can still answer calls and see notifications.';

  @override
  String get appLockSwitch => 'Require unlock';

  @override
  String get appLockSwitchHint => 'Face ID, Touch ID or passcode';

  @override
  String get appLockAfter => 'Lock after';

  @override
  String get appLockImmediately => 'Immediately';

  @override
  String get appLockOneMinute => '1 minute';

  @override
  String get appLockFifteenMinutes => '15 minutes';

  @override
  String get appLockOneHour => '1 hour';

  @override
  String get devicesThisDevice => 'This device';

  @override
  String get devicesOtherDevices => 'Other devices';

  @override
  String get devicesFooter =>
      'Signing a device out ends its session right away. It will need a new code to sign back in.';

  @override
  String get devicesNone => 'No other devices are signed in.';

  @override
  String get devicesActiveNow => 'Active now';

  @override
  String get devicesSignOut => 'Sign out';

  @override
  String devicesSignOutTitle(String device) {
    return 'Sign out of $device?';
  }

  @override
  String get devicesSignOutBody =>
      'That device will be signed out immediately.';

  @override
  String get devicesSignOutOthers => 'Sign out of all other devices';

  @override
  String get devicesSignOutOthersBody =>
      'Every device except this one will be signed out immediately.';

  @override
  String devicesSignedOutCount(int count) {
    String _temp0 = intl.Intl.pluralLogic(
      count,
      locale: localeName,
      other: 'Signed out of $count devices',
      one: 'Signed out of 1 device',
      zero: 'No other devices were signed in',
    );
    return '$_temp0';
  }

  @override
  String get pinOffFooter =>
      'Add a 6-digit PIN that every new device must enter after the SMS code. It protects your account if someone takes over your number.';

  @override
  String get pinOnFooter =>
      'Two-step verification is on. New devices must enter your PIN after the SMS code.';

  @override
  String get pinTurnOn => 'Turn on';

  @override
  String get pinChange => 'Change PIN';

  @override
  String get pinTurnOff => 'Turn off';

  @override
  String get pinNew => 'New PIN';

  @override
  String get pinConfirm => 'Confirm PIN';

  @override
  String get pinCurrent => 'Current PIN';

  @override
  String get pinMismatch => 'The PINs don\'t match.';

  @override
  String get pinEnabledToast => 'Two-step verification is on.';

  @override
  String get pinChangedToast => 'PIN changed.';

  @override
  String get pinDisabledToast => 'Two-step verification is off.';

  @override
  String get pinGateTitle => 'Enter your PIN';

  @override
  String get pinGateBody =>
      'This account has two-step verification. Enter the 6-digit PIN you set up.';

  @override
  String get pinGateHint => '6-digit PIN';

  @override
  String get pinGateContinue => 'Continue';

  @override
  String get pinGateForgot => 'Forgot PIN?';

  @override
  String get pinGateForgotTitle => 'Remove your PIN?';

  @override
  String get pinGateForgotBody =>
      'For your safety the PIN is removed after 7 days. Entering it before then cancels the removal.';

  @override
  String get pinGateForgotAction => 'Start 7-day wait';

  @override
  String pinGateResetPending(String date) {
    return 'Your PIN will be removed on $date. Enter it before then to cancel.';
  }

  @override
  String get changeNumberIntro =>
      'Your chats, contacts and groups move with you to the new number.';

  @override
  String changeNumberIntroCurrent(String phone) {
    return 'Current number: $phone. Your chats, contacts and groups move with you to the new number.';
  }

  @override
  String get changeNumberSend => 'Send code';

  @override
  String changeNumberSentTo(String phone) {
    return 'Code sent to $phone';
  }

  @override
  String get changeNumberCodeHint => '6-digit code';

  @override
  String get changeNumberVerify => 'Verify';

  @override
  String get changeNumberEditNumber => 'Use a different number';

  @override
  String changeNumberDone(String phone) {
    return 'Your number is now $phone';
  }

  @override
  String get changeNumberFooter =>
      'The new number must not be on another Doqto account. Your old number stops working for sign-in straight away.';

  @override
  String get helpSupportSection => 'Support';

  @override
  String get helpLegalSection => 'Legal';

  @override
  String get helpCentre => 'Help centre';

  @override
  String get helpContact => 'Contact us';

  @override
  String get helpTerms => 'Terms of service';

  @override
  String get helpPrivacy => 'Privacy policy';

  @override
  String get helpHipaa => 'HIPAA notice';

  @override
  String get helpLicences => 'Open-source licences';

  @override
  String get helpOpenFailed => 'Couldn\'t open the link.';

  @override
  String get languageFooter =>
      'Changes the language of Doqto only. Messages are never translated.';

  @override
  String get forceUpdateTitle => 'Update Doqto';

  @override
  String get forceUpdateBody =>
      'This version is no longer supported. Update to keep messaging.';

  @override
  String get forceUpdateButton => 'Update';

  @override
  String get storageTitle => 'Storage and data';
}
