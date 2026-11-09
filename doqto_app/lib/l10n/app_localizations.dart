import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:intl/intl.dart' as intl;

import 'app_localizations_en.dart';
import 'app_localizations_es.dart';

// ignore_for_file: type=lint

/// Callers can lookup localized strings with an instance of AppLocalizations
/// returned by `AppLocalizations.of(context)`.
///
/// Applications need to include `AppLocalizations.delegate()` in their app's
/// `localizationDelegates` list, and the locales they support in the app's
/// `supportedLocales` list. For example:
///
/// ```dart
/// import 'l10n/app_localizations.dart';
///
/// return MaterialApp(
///   localizationsDelegates: AppLocalizations.localizationsDelegates,
///   supportedLocales: AppLocalizations.supportedLocales,
///   home: MyApplicationHome(),
/// );
/// ```
///
/// ## Update pubspec.yaml
///
/// Please make sure to update your pubspec.yaml to include the following
/// packages:
///
/// ```yaml
/// dependencies:
///   # Internationalization support.
///   flutter_localizations:
///     sdk: flutter
///   intl: any # Use the pinned version from flutter_localizations
///
///   # Rest of dependencies
/// ```
///
/// ## iOS Applications
///
/// iOS applications define key application metadata, including supported
/// locales, in an Info.plist file that is built into the application bundle.
/// To configure the locales supported by your app, you’ll need to edit this
/// file.
///
/// First, open your project’s ios/Runner.xcworkspace Xcode workspace file.
/// Then, in the Project Navigator, open the Info.plist file under the Runner
/// project’s Runner folder.
///
/// Next, select the Information Property List item, select Add Item from the
/// Editor menu, then select Localizations from the pop-up menu.
///
/// Select and expand the newly-created Localizations item then, for each
/// locale your application supports, add a new item and select the locale
/// you wish to add from the pop-up menu in the Value field. This list should
/// be consistent with the languages listed in the AppLocalizations.supportedLocales
/// property.
abstract class AppLocalizations {
  AppLocalizations(String locale)
    : localeName = intl.Intl.canonicalizedLocale(locale.toString());

  final String localeName;

  static AppLocalizations of(BuildContext context) {
    return Localizations.of<AppLocalizations>(context, AppLocalizations)!;
  }

  static const LocalizationsDelegate<AppLocalizations> delegate =
      _AppLocalizationsDelegate();

  /// A list of this localizations delegate along with the default localizations
  /// delegates.
  ///
  /// Returns a list of localizations delegates containing this delegate along with
  /// GlobalMaterialLocalizations.delegate, GlobalCupertinoLocalizations.delegate,
  /// and GlobalWidgetsLocalizations.delegate.
  ///
  /// Additional delegates can be added by appending to this list in
  /// MaterialApp. This list does not have to be used at all if a custom list
  /// of delegates is preferred or required.
  static const List<LocalizationsDelegate<dynamic>> localizationsDelegates =
      <LocalizationsDelegate<dynamic>>[
        delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
      ];

  /// A list of this localizations delegate's supported locales.
  static const List<Locale> supportedLocales = <Locale>[
    Locale('en'),
    Locale('es'),
  ];

  /// No description provided for @settingsTitle.
  ///
  /// In en, this message translates to:
  /// **'Settings'**
  String get settingsTitle;

  /// No description provided for @settingsAccount.
  ///
  /// In en, this message translates to:
  /// **'Account'**
  String get settingsAccount;

  /// No description provided for @settingsPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy'**
  String get settingsPrivacy;

  /// No description provided for @settingsPrivacySubtitle.
  ///
  /// In en, this message translates to:
  /// **'Last seen, read receipts, who can reach you'**
  String get settingsPrivacySubtitle;

  /// No description provided for @settingsAppearance.
  ///
  /// In en, this message translates to:
  /// **'Chats & appearance'**
  String get settingsAppearance;

  /// No description provided for @settingsAppearanceSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Chat colour, wallpaper, font size'**
  String get settingsAppearanceSubtitle;

  /// No description provided for @settingsNotifications.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get settingsNotifications;

  /// No description provided for @settingsNotificationsSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Tones, vibration, previews'**
  String get settingsNotificationsSubtitle;

  /// No description provided for @settingsStorage.
  ///
  /// In en, this message translates to:
  /// **'Storage and data'**
  String get settingsStorage;

  /// No description provided for @settingsStorageSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Media, downloads and usage'**
  String get settingsStorageSubtitle;

  /// No description provided for @settingsLanguage.
  ///
  /// In en, this message translates to:
  /// **'App language'**
  String get settingsLanguage;

  /// No description provided for @settingsHelp.
  ///
  /// In en, this message translates to:
  /// **'Help'**
  String get settingsHelp;

  /// No description provided for @settingsHelpSubtitle.
  ///
  /// In en, this message translates to:
  /// **'Help centre, contact us, terms and privacy'**
  String get settingsHelpSubtitle;

  /// No description provided for @settingsStarred.
  ///
  /// In en, this message translates to:
  /// **'Starred messages'**
  String get settingsStarred;

  /// No description provided for @settingsLinkedDevices.
  ///
  /// In en, this message translates to:
  /// **'Linked devices'**
  String get settingsLinkedDevices;

  /// No description provided for @settingsTwoStep.
  ///
  /// In en, this message translates to:
  /// **'Two-step verification'**
  String get settingsTwoStep;

  /// No description provided for @settingsChangeNumber.
  ///
  /// In en, this message translates to:
  /// **'Change number'**
  String get settingsChangeNumber;

  /// No description provided for @settingsExport.
  ///
  /// In en, this message translates to:
  /// **'Request account info'**
  String get settingsExport;

  /// No description provided for @settingsAppLock.
  ///
  /// In en, this message translates to:
  /// **'App lock'**
  String get settingsAppLock;

  /// No description provided for @settingsSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get settingsSignOut;

  /// No description provided for @settingsDeleteAccount.
  ///
  /// In en, this message translates to:
  /// **'Delete account'**
  String get settingsDeleteAccount;

  /// No description provided for @settingsVersion.
  ///
  /// In en, this message translates to:
  /// **'Version {version}'**
  String settingsVersion(String version);

  /// No description provided for @languageSystem.
  ///
  /// In en, this message translates to:
  /// **'System default'**
  String get languageSystem;

  /// No description provided for @languageEnglish.
  ///
  /// In en, this message translates to:
  /// **'English'**
  String get languageEnglish;

  /// No description provided for @languageSpanish.
  ///
  /// In en, this message translates to:
  /// **'Español'**
  String get languageSpanish;

  /// No description provided for @commonCancel.
  ///
  /// In en, this message translates to:
  /// **'Cancel'**
  String get commonCancel;

  /// No description provided for @commonSave.
  ///
  /// In en, this message translates to:
  /// **'Save'**
  String get commonSave;

  /// No description provided for @commonDone.
  ///
  /// In en, this message translates to:
  /// **'Done'**
  String get commonDone;

  /// No description provided for @commonRetry.
  ///
  /// In en, this message translates to:
  /// **'Retry'**
  String get commonRetry;

  /// No description provided for @commonOn.
  ///
  /// In en, this message translates to:
  /// **'On'**
  String get commonOn;

  /// No description provided for @commonOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get commonOff;

  /// No description provided for @commonSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t save that. Try again.'**
  String get commonSaveFailed;

  /// No description provided for @chatsTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get chatsTitle;

  /// No description provided for @chatsSearchHint.
  ///
  /// In en, this message translates to:
  /// **'Search chats'**
  String get chatsSearchHint;

  /// No description provided for @chatsEmptyTitle.
  ///
  /// In en, this message translates to:
  /// **'No conversations yet'**
  String get chatsEmptyTitle;

  /// No description provided for @chatsEmptyBody.
  ///
  /// In en, this message translates to:
  /// **'Start a message with a colleague to see it here.'**
  String get chatsEmptyBody;

  /// No description provided for @chatsArchived.
  ///
  /// In en, this message translates to:
  /// **'Archived'**
  String get chatsArchived;

  /// No description provided for @chatsDraftPrefix.
  ///
  /// In en, this message translates to:
  /// **'Draft: '**
  String get chatsDraftPrefix;

  /// No description provided for @threadMessageHint.
  ///
  /// In en, this message translates to:
  /// **'Message'**
  String get threadMessageHint;

  /// No description provided for @threadTyping.
  ///
  /// In en, this message translates to:
  /// **'typing…'**
  String get threadTyping;

  /// No description provided for @threadOnline.
  ///
  /// In en, this message translates to:
  /// **'online'**
  String get threadOnline;

  /// No description provided for @threadSearch.
  ///
  /// In en, this message translates to:
  /// **'Search in chat'**
  String get threadSearch;

  /// No description provided for @threadReply.
  ///
  /// In en, this message translates to:
  /// **'Reply'**
  String get threadReply;

  /// No description provided for @threadForward.
  ///
  /// In en, this message translates to:
  /// **'Forward'**
  String get threadForward;

  /// No description provided for @threadCopy.
  ///
  /// In en, this message translates to:
  /// **'Copy'**
  String get threadCopy;

  /// No description provided for @threadDelete.
  ///
  /// In en, this message translates to:
  /// **'Delete'**
  String get threadDelete;

  /// No description provided for @threadEdited.
  ///
  /// In en, this message translates to:
  /// **'edited'**
  String get threadEdited;

  /// No description provided for @threadMessageDeleted.
  ///
  /// In en, this message translates to:
  /// **'Message deleted'**
  String get threadMessageDeleted;

  /// No description provided for @appearanceTitle.
  ///
  /// In en, this message translates to:
  /// **'Chats & appearance'**
  String get appearanceTitle;

  /// No description provided for @appearanceDisplay.
  ///
  /// In en, this message translates to:
  /// **'Display'**
  String get appearanceDisplay;

  /// No description provided for @appearanceFontSize.
  ///
  /// In en, this message translates to:
  /// **'Font size'**
  String get appearanceFontSize;

  /// No description provided for @appearanceFontSmall.
  ///
  /// In en, this message translates to:
  /// **'Small'**
  String get appearanceFontSmall;

  /// No description provided for @appearanceFontMedium.
  ///
  /// In en, this message translates to:
  /// **'Medium'**
  String get appearanceFontMedium;

  /// No description provided for @appearanceFontLarge.
  ///
  /// In en, this message translates to:
  /// **'Large'**
  String get appearanceFontLarge;

  /// No description provided for @appearanceFontHint.
  ///
  /// In en, this message translates to:
  /// **'Follows your phone\'s text size too'**
  String get appearanceFontHint;

  /// No description provided for @appearancePreview.
  ///
  /// In en, this message translates to:
  /// **'Secure messaging that fits your day.'**
  String get appearancePreview;

  /// No description provided for @appearanceChatsSection.
  ///
  /// In en, this message translates to:
  /// **'Chats'**
  String get appearanceChatsSection;

  /// No description provided for @appearanceDefaultChatTheme.
  ///
  /// In en, this message translates to:
  /// **'Default chat colour'**
  String get appearanceDefaultChatTheme;

  /// No description provided for @appearanceDefaultWallpaper.
  ///
  /// In en, this message translates to:
  /// **'Default wallpaper'**
  String get appearanceDefaultWallpaper;

  /// No description provided for @appearanceWallpaperNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get appearanceWallpaperNone;

  /// No description provided for @appearanceWallpaperPhoto.
  ///
  /// In en, this message translates to:
  /// **'Your photo'**
  String get appearanceWallpaperPhoto;

  /// No description provided for @appearanceEnterIsSend.
  ///
  /// In en, this message translates to:
  /// **'Enter is send'**
  String get appearanceEnterIsSend;

  /// No description provided for @appearanceEnterIsSendHint.
  ///
  /// In en, this message translates to:
  /// **'Return key sends instead of adding a line'**
  String get appearanceEnterIsSendHint;

  /// No description provided for @appearanceVoiceTranscript.
  ///
  /// In en, this message translates to:
  /// **'Voice note transcript'**
  String get appearanceVoiceTranscript;

  /// No description provided for @appearanceVoiceTranscriptHint.
  ///
  /// In en, this message translates to:
  /// **'Transcribe voice notes while you record'**
  String get appearanceVoiceTranscriptHint;

  /// No description provided for @appearanceKeepArchived.
  ///
  /// In en, this message translates to:
  /// **'Keep chats archived'**
  String get appearanceKeepArchived;

  /// No description provided for @appearanceKeepArchivedHint.
  ///
  /// In en, this message translates to:
  /// **'Archived chats stay archived when a new message arrives'**
  String get appearanceKeepArchivedHint;

  /// No description provided for @chatThemeTitle.
  ///
  /// In en, this message translates to:
  /// **'Chat colour'**
  String get chatThemeTitle;

  /// No description provided for @chatThemeDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get chatThemeDefault;

  /// No description provided for @chatThemeDefaultHint.
  ///
  /// In en, this message translates to:
  /// **'Uses your default chat colour'**
  String get chatThemeDefaultHint;

  /// No description provided for @chatThemeSent.
  ///
  /// In en, this message translates to:
  /// **'Sounds good, see you at 3'**
  String get chatThemeSent;

  /// No description provided for @chatThemeReceived.
  ///
  /// In en, this message translates to:
  /// **'Can we move rounds to 3?'**
  String get chatThemeReceived;

  /// No description provided for @chatThemeSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change the chat colour. Try again.'**
  String get chatThemeSaveFailed;

  /// No description provided for @wallpaperTitle.
  ///
  /// In en, this message translates to:
  /// **'Wallpaper'**
  String get wallpaperTitle;

  /// No description provided for @wallpaperPatterns.
  ///
  /// In en, this message translates to:
  /// **'Patterns'**
  String get wallpaperPatterns;

  /// No description provided for @wallpaperSolids.
  ///
  /// In en, this message translates to:
  /// **'Solid colours'**
  String get wallpaperSolids;

  /// No description provided for @wallpaperPhoto.
  ///
  /// In en, this message translates to:
  /// **'Choose from photos'**
  String get wallpaperPhoto;

  /// No description provided for @wallpaperNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get wallpaperNone;

  /// No description provided for @wallpaperSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t change the wallpaper. Try again.'**
  String get wallpaperSaveFailed;

  /// No description provided for @statusTitle.
  ///
  /// In en, this message translates to:
  /// **'Status'**
  String get statusTitle;

  /// No description provided for @statusPresets.
  ///
  /// In en, this message translates to:
  /// **'Presets'**
  String get statusPresets;

  /// No description provided for @statusCustom.
  ///
  /// In en, this message translates to:
  /// **'Custom'**
  String get statusCustom;

  /// No description provided for @statusCustomHint.
  ///
  /// In en, this message translates to:
  /// **'What should colleagues know?'**
  String get statusCustomHint;

  /// No description provided for @statusClearAfter.
  ///
  /// In en, this message translates to:
  /// **'Clear after'**
  String get statusClearAfter;

  /// No description provided for @statusOneHour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get statusOneHour;

  /// No description provided for @statusEightHours.
  ///
  /// In en, this message translates to:
  /// **'8 hours'**
  String get statusEightHours;

  /// No description provided for @statusOneDay.
  ///
  /// In en, this message translates to:
  /// **'24 hours'**
  String get statusOneDay;

  /// No description provided for @statusNever.
  ///
  /// In en, this message translates to:
  /// **'Never'**
  String get statusNever;

  /// No description provided for @statusSave.
  ///
  /// In en, this message translates to:
  /// **'Save status'**
  String get statusSave;

  /// No description provided for @statusClear.
  ///
  /// In en, this message translates to:
  /// **'Clear status'**
  String get statusClear;

  /// No description provided for @statusNone.
  ///
  /// In en, this message translates to:
  /// **'No status'**
  String get statusNone;

  /// No description provided for @statusSaveFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t update your status. Try again.'**
  String get statusSaveFailed;

  /// No description provided for @notifTitle.
  ///
  /// In en, this message translates to:
  /// **'Notifications'**
  String get notifTitle;

  /// No description provided for @notifMessages.
  ///
  /// In en, this message translates to:
  /// **'Messages'**
  String get notifMessages;

  /// No description provided for @notifGroups.
  ///
  /// In en, this message translates to:
  /// **'Groups'**
  String get notifGroups;

  /// No description provided for @notifTone.
  ///
  /// In en, this message translates to:
  /// **'Tone'**
  String get notifTone;

  /// No description provided for @notifVibrate.
  ///
  /// In en, this message translates to:
  /// **'Vibrate'**
  String get notifVibrate;

  /// No description provided for @notifVibrateDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get notifVibrateDefault;

  /// No description provided for @notifVibrateShort.
  ///
  /// In en, this message translates to:
  /// **'Short'**
  String get notifVibrateShort;

  /// No description provided for @notifVibrateLong.
  ///
  /// In en, this message translates to:
  /// **'Long'**
  String get notifVibrateLong;

  /// No description provided for @notifVibrateOff.
  ///
  /// In en, this message translates to:
  /// **'Off'**
  String get notifVibrateOff;

  /// No description provided for @notifVibrateIosFooter.
  ///
  /// In en, this message translates to:
  /// **'Vibration follows your iPhone settings.'**
  String get notifVibrateIosFooter;

  /// No description provided for @notifShowPreview.
  ///
  /// In en, this message translates to:
  /// **'Show preview'**
  String get notifShowPreview;

  /// No description provided for @notifShowPreviewHint.
  ///
  /// In en, this message translates to:
  /// **'Show message text in banners'**
  String get notifShowPreviewHint;

  /// No description provided for @notifHighPriority.
  ///
  /// In en, this message translates to:
  /// **'High priority'**
  String get notifHighPriority;

  /// No description provided for @notifHighPriorityHint.
  ///
  /// In en, this message translates to:
  /// **'Show banners at the top of the screen'**
  String get notifHighPriorityHint;

  /// No description provided for @notifReactions.
  ///
  /// In en, this message translates to:
  /// **'Reactions'**
  String get notifReactions;

  /// No description provided for @notifReactionNotifications.
  ///
  /// In en, this message translates to:
  /// **'Reaction notifications'**
  String get notifReactionNotifications;

  /// No description provided for @notifReactionNotificationsHint.
  ///
  /// In en, this message translates to:
  /// **'Notify when someone reacts to your message'**
  String get notifReactionNotificationsHint;

  /// No description provided for @notifInApp.
  ///
  /// In en, this message translates to:
  /// **'In-app'**
  String get notifInApp;

  /// No description provided for @notifConversationTones.
  ///
  /// In en, this message translates to:
  /// **'Conversation tones'**
  String get notifConversationTones;

  /// No description provided for @notifConversationTonesHint.
  ///
  /// In en, this message translates to:
  /// **'Play sounds for incoming and outgoing messages'**
  String get notifConversationTonesHint;

  /// No description provided for @notifHaptics.
  ///
  /// In en, this message translates to:
  /// **'Haptics'**
  String get notifHaptics;

  /// No description provided for @notifHapticsHint.
  ///
  /// In en, this message translates to:
  /// **'Light vibration on new messages'**
  String get notifHapticsHint;

  /// No description provided for @notifReset.
  ///
  /// In en, this message translates to:
  /// **'Reset notification settings'**
  String get notifReset;

  /// No description provided for @notifResetTitle.
  ///
  /// In en, this message translates to:
  /// **'Reset notification settings?'**
  String get notifResetTitle;

  /// No description provided for @notifResetBody.
  ///
  /// In en, this message translates to:
  /// **'All tones, vibration and preview choices go back to the defaults. Custom notifications for individual chats are kept.'**
  String get notifResetBody;

  /// No description provided for @notifResetConfirm.
  ///
  /// In en, this message translates to:
  /// **'Reset'**
  String get notifResetConfirm;

  /// No description provided for @notifResetDone.
  ///
  /// In en, this message translates to:
  /// **'Notification settings reset'**
  String get notifResetDone;

  /// No description provided for @toneTitle.
  ///
  /// In en, this message translates to:
  /// **'Tone'**
  String get toneTitle;

  /// No description provided for @toneDefault.
  ///
  /// In en, this message translates to:
  /// **'Default'**
  String get toneDefault;

  /// No description provided for @toneNone.
  ///
  /// In en, this message translates to:
  /// **'None'**
  String get toneNone;

  /// No description provided for @toneHint.
  ///
  /// In en, this message translates to:
  /// **'Tap a tone to hear it.'**
  String get toneHint;

  /// No description provided for @chatNotifTitle.
  ///
  /// In en, this message translates to:
  /// **'Custom notifications'**
  String get chatNotifTitle;

  /// No description provided for @chatNotifUseCustom.
  ///
  /// In en, this message translates to:
  /// **'Use custom notifications'**
  String get chatNotifUseCustom;

  /// No description provided for @chatNotifUseCustomHint.
  ///
  /// In en, this message translates to:
  /// **'Pick a tone and vibration for this chat only'**
  String get chatNotifUseCustomHint;

  /// No description provided for @chatNotifMute.
  ///
  /// In en, this message translates to:
  /// **'Mute notifications'**
  String get chatNotifMute;

  /// No description provided for @chatNotifMuted.
  ///
  /// In en, this message translates to:
  /// **'Muted'**
  String get chatNotifMuted;

  /// No description provided for @chatNotifNotMuted.
  ///
  /// In en, this message translates to:
  /// **'Not muted'**
  String get chatNotifNotMuted;

  /// No description provided for @chatNotifUnmute.
  ///
  /// In en, this message translates to:
  /// **'Unmute'**
  String get chatNotifUnmute;

  /// No description provided for @appLockLockedTitle.
  ///
  /// In en, this message translates to:
  /// **'Doqto is locked'**
  String get appLockLockedTitle;

  /// No description provided for @appLockLockedBody.
  ///
  /// In en, this message translates to:
  /// **'Unlock with Face ID, Touch ID or your passcode.'**
  String get appLockLockedBody;

  /// No description provided for @appLockUnlock.
  ///
  /// In en, this message translates to:
  /// **'Unlock'**
  String get appLockUnlock;

  /// No description provided for @appLockUnavailable.
  ///
  /// In en, this message translates to:
  /// **'Set up a passcode or biometrics on this phone first.'**
  String get appLockUnavailable;

  /// No description provided for @appLockEnableReason.
  ///
  /// In en, this message translates to:
  /// **'Confirm it\'s you to turn on app lock'**
  String get appLockEnableReason;

  /// No description provided for @appLockNotVerified.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t verify — app lock stays off.'**
  String get appLockNotVerified;

  /// No description provided for @appLockFooter.
  ///
  /// In en, this message translates to:
  /// **'When on, Doqto asks for Face ID, Touch ID or your passcode when you come back to it. You can still answer calls and see notifications.'**
  String get appLockFooter;

  /// No description provided for @appLockSwitch.
  ///
  /// In en, this message translates to:
  /// **'Require unlock'**
  String get appLockSwitch;

  /// No description provided for @appLockSwitchHint.
  ///
  /// In en, this message translates to:
  /// **'Face ID, Touch ID or passcode'**
  String get appLockSwitchHint;

  /// No description provided for @appLockAfter.
  ///
  /// In en, this message translates to:
  /// **'Lock after'**
  String get appLockAfter;

  /// No description provided for @appLockImmediately.
  ///
  /// In en, this message translates to:
  /// **'Immediately'**
  String get appLockImmediately;

  /// No description provided for @appLockOneMinute.
  ///
  /// In en, this message translates to:
  /// **'1 minute'**
  String get appLockOneMinute;

  /// No description provided for @appLockFifteenMinutes.
  ///
  /// In en, this message translates to:
  /// **'15 minutes'**
  String get appLockFifteenMinutes;

  /// No description provided for @appLockOneHour.
  ///
  /// In en, this message translates to:
  /// **'1 hour'**
  String get appLockOneHour;

  /// No description provided for @devicesThisDevice.
  ///
  /// In en, this message translates to:
  /// **'This device'**
  String get devicesThisDevice;

  /// No description provided for @devicesOtherDevices.
  ///
  /// In en, this message translates to:
  /// **'Other devices'**
  String get devicesOtherDevices;

  /// No description provided for @devicesFooter.
  ///
  /// In en, this message translates to:
  /// **'Signing a device out ends its session right away. It will need a new code to sign back in.'**
  String get devicesFooter;

  /// No description provided for @devicesNone.
  ///
  /// In en, this message translates to:
  /// **'No other devices are signed in.'**
  String get devicesNone;

  /// No description provided for @devicesActiveNow.
  ///
  /// In en, this message translates to:
  /// **'Active now'**
  String get devicesActiveNow;

  /// No description provided for @devicesSignOut.
  ///
  /// In en, this message translates to:
  /// **'Sign out'**
  String get devicesSignOut;

  /// No description provided for @devicesSignOutTitle.
  ///
  /// In en, this message translates to:
  /// **'Sign out of {device}?'**
  String devicesSignOutTitle(String device);

  /// No description provided for @devicesSignOutBody.
  ///
  /// In en, this message translates to:
  /// **'That device will be signed out immediately.'**
  String get devicesSignOutBody;

  /// No description provided for @devicesSignOutOthers.
  ///
  /// In en, this message translates to:
  /// **'Sign out of all other devices'**
  String get devicesSignOutOthers;

  /// No description provided for @devicesSignOutOthersBody.
  ///
  /// In en, this message translates to:
  /// **'Every device except this one will be signed out immediately.'**
  String get devicesSignOutOthersBody;

  /// No description provided for @devicesSignedOutCount.
  ///
  /// In en, this message translates to:
  /// **'{count, plural, =0{No other devices were signed in} =1{Signed out of 1 device} other{Signed out of {count} devices}}'**
  String devicesSignedOutCount(int count);

  /// No description provided for @pinOffFooter.
  ///
  /// In en, this message translates to:
  /// **'Add a 6-digit PIN that every new device must enter after the SMS code. It protects your account if someone takes over your number.'**
  String get pinOffFooter;

  /// No description provided for @pinOnFooter.
  ///
  /// In en, this message translates to:
  /// **'Two-step verification is on. New devices must enter your PIN after the SMS code.'**
  String get pinOnFooter;

  /// No description provided for @pinTurnOn.
  ///
  /// In en, this message translates to:
  /// **'Turn on'**
  String get pinTurnOn;

  /// No description provided for @pinChange.
  ///
  /// In en, this message translates to:
  /// **'Change PIN'**
  String get pinChange;

  /// No description provided for @pinTurnOff.
  ///
  /// In en, this message translates to:
  /// **'Turn off'**
  String get pinTurnOff;

  /// No description provided for @pinNew.
  ///
  /// In en, this message translates to:
  /// **'New PIN'**
  String get pinNew;

  /// No description provided for @pinConfirm.
  ///
  /// In en, this message translates to:
  /// **'Confirm PIN'**
  String get pinConfirm;

  /// No description provided for @pinCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current PIN'**
  String get pinCurrent;

  /// No description provided for @pinMismatch.
  ///
  /// In en, this message translates to:
  /// **'The PINs don\'t match.'**
  String get pinMismatch;

  /// No description provided for @pinEnabledToast.
  ///
  /// In en, this message translates to:
  /// **'Two-step verification is on.'**
  String get pinEnabledToast;

  /// No description provided for @pinChangedToast.
  ///
  /// In en, this message translates to:
  /// **'PIN changed.'**
  String get pinChangedToast;

  /// No description provided for @pinDisabledToast.
  ///
  /// In en, this message translates to:
  /// **'Two-step verification is off.'**
  String get pinDisabledToast;

  /// No description provided for @pinGateTitle.
  ///
  /// In en, this message translates to:
  /// **'Enter your PIN'**
  String get pinGateTitle;

  /// No description provided for @pinGateBody.
  ///
  /// In en, this message translates to:
  /// **'This account has two-step verification. Enter the 6-digit PIN you set up.'**
  String get pinGateBody;

  /// No description provided for @pinGateHint.
  ///
  /// In en, this message translates to:
  /// **'6-digit PIN'**
  String get pinGateHint;

  /// No description provided for @pinGateContinue.
  ///
  /// In en, this message translates to:
  /// **'Continue'**
  String get pinGateContinue;

  /// No description provided for @pinGateForgot.
  ///
  /// In en, this message translates to:
  /// **'Forgot PIN?'**
  String get pinGateForgot;

  /// No description provided for @pinGateForgotTitle.
  ///
  /// In en, this message translates to:
  /// **'Remove your PIN?'**
  String get pinGateForgotTitle;

  /// No description provided for @pinGateForgotBody.
  ///
  /// In en, this message translates to:
  /// **'For your safety the PIN is removed after 7 days. Entering it before then cancels the removal.'**
  String get pinGateForgotBody;

  /// No description provided for @pinGateForgotAction.
  ///
  /// In en, this message translates to:
  /// **'Start 7-day wait'**
  String get pinGateForgotAction;

  /// No description provided for @pinGateResetPending.
  ///
  /// In en, this message translates to:
  /// **'Your PIN will be removed on {date}. Enter it before then to cancel.'**
  String pinGateResetPending(String date);

  /// No description provided for @changeNumberIntro.
  ///
  /// In en, this message translates to:
  /// **'Your chats, contacts and groups move with you to the new number.'**
  String get changeNumberIntro;

  /// No description provided for @changeNumberIntroCurrent.
  ///
  /// In en, this message translates to:
  /// **'Current number: {phone}. Your chats, contacts and groups move with you to the new number.'**
  String changeNumberIntroCurrent(String phone);

  /// No description provided for @changeNumberSend.
  ///
  /// In en, this message translates to:
  /// **'Send code'**
  String get changeNumberSend;

  /// No description provided for @changeNumberSentTo.
  ///
  /// In en, this message translates to:
  /// **'Code sent to {phone}'**
  String changeNumberSentTo(String phone);

  /// No description provided for @changeNumberCodeHint.
  ///
  /// In en, this message translates to:
  /// **'6-digit code'**
  String get changeNumberCodeHint;

  /// No description provided for @changeNumberVerify.
  ///
  /// In en, this message translates to:
  /// **'Verify'**
  String get changeNumberVerify;

  /// No description provided for @changeNumberEditNumber.
  ///
  /// In en, this message translates to:
  /// **'Use a different number'**
  String get changeNumberEditNumber;

  /// No description provided for @changeNumberDone.
  ///
  /// In en, this message translates to:
  /// **'Your number is now {phone}'**
  String changeNumberDone(String phone);

  /// No description provided for @changeNumberFooter.
  ///
  /// In en, this message translates to:
  /// **'The new number must not be on another Doqto account. Your old number stops working for sign-in straight away.'**
  String get changeNumberFooter;

  /// No description provided for @helpSupportSection.
  ///
  /// In en, this message translates to:
  /// **'Support'**
  String get helpSupportSection;

  /// No description provided for @helpLegalSection.
  ///
  /// In en, this message translates to:
  /// **'Legal'**
  String get helpLegalSection;

  /// No description provided for @helpCentre.
  ///
  /// In en, this message translates to:
  /// **'Help centre'**
  String get helpCentre;

  /// No description provided for @helpContact.
  ///
  /// In en, this message translates to:
  /// **'Contact us'**
  String get helpContact;

  /// No description provided for @helpTerms.
  ///
  /// In en, this message translates to:
  /// **'Terms of service'**
  String get helpTerms;

  /// No description provided for @helpPrivacy.
  ///
  /// In en, this message translates to:
  /// **'Privacy policy'**
  String get helpPrivacy;

  /// No description provided for @helpHipaa.
  ///
  /// In en, this message translates to:
  /// **'HIPAA notice'**
  String get helpHipaa;

  /// No description provided for @helpLicences.
  ///
  /// In en, this message translates to:
  /// **'Open-source licences'**
  String get helpLicences;

  /// No description provided for @helpOpenFailed.
  ///
  /// In en, this message translates to:
  /// **'Couldn\'t open the link.'**
  String get helpOpenFailed;

  /// No description provided for @languageFooter.
  ///
  /// In en, this message translates to:
  /// **'Changes the language of Doqto only. Messages are never translated.'**
  String get languageFooter;

  /// No description provided for @forceUpdateTitle.
  ///
  /// In en, this message translates to:
  /// **'Update Doqto'**
  String get forceUpdateTitle;

  /// No description provided for @forceUpdateBody.
  ///
  /// In en, this message translates to:
  /// **'This version is no longer supported. Update to keep messaging.'**
  String get forceUpdateBody;

  /// No description provided for @forceUpdateButton.
  ///
  /// In en, this message translates to:
  /// **'Update'**
  String get forceUpdateButton;

  /// No description provided for @storageTitle.
  ///
  /// In en, this message translates to:
  /// **'Storage and data'**
  String get storageTitle;
}

class _AppLocalizationsDelegate
    extends LocalizationsDelegate<AppLocalizations> {
  const _AppLocalizationsDelegate();

  @override
  Future<AppLocalizations> load(Locale locale) {
    return SynchronousFuture<AppLocalizations>(lookupAppLocalizations(locale));
  }

  @override
  bool isSupported(Locale locale) =>
      <String>['en', 'es'].contains(locale.languageCode);

  @override
  bool shouldReload(_AppLocalizationsDelegate old) => false;
}

AppLocalizations lookupAppLocalizations(Locale locale) {
  // Lookup logic when only language code is specified.
  switch (locale.languageCode) {
    case 'en':
      return AppLocalizationsEn();
    case 'es':
      return AppLocalizationsEs();
  }

  throw FlutterError(
    'AppLocalizations.delegate failed to load unsupported locale "$locale". This is likely '
    'an issue with the localizations generation tool. Please file an issue '
    'on GitHub with a reproducible sample app and the gen-l10n configuration '
    'that was used.',
  );
}
