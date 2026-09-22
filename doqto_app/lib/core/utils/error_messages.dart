// Physician-facing error copy. Single source of truth for user-visible messages
// mapped from backend error codes (HTTPException detail strings).
//
// Voice & tone rules:
//  - Calm, clinical, actionable. No tech jargon, no HTTP codes, no stack traces.
//  - Lead with what happened, follow with what to do next.
//  - Reference domain nouns doctors know: "invite code", "org admin", "NPI", "organization".
//  - Under ~90 chars so it fits one or two lines under an input.
//  - Never end with just "Error:" — always propose the next action.
//
// Backend codes are load-bearing here: renaming a code in the Python services
// without updating this map will fall through to a generic HTTP-family fallback.

import 'dart:async';

import '../../data/api/api_client.dart';
import '../../data/services/auth_broker.dart';

class ErrorMessages {
  ErrorMessages._();

  static const Map<String, String> _byCode = {
    // Message edit / delete (sender-only, time-boxed)
    'not_connected': 'Connect with this doctor to message them.',
    'edit_window_closed':
        'Messages can only be edited within 5 minutes of sending.',
    'delete_window_closed':
        'Messages can only be deleted within 3 minutes of sending.',
    'message_deleted': 'This message was already deleted.',
    'not_message_sender': 'You can only change your own messages.',
    // Auth / OTP
    'otp_expired': 'That code has expired. Tap "Resend code" and try again.',
    'otp_invalid':
        'That code doesn\'t match. Please re-enter the 6-digit code we sent.',
    'otp_too_many_attempts':
        'Too many attempts. Please wait a few minutes before requesting a new code.',
    'otp_resend_cooldown':
        'Please wait a few seconds before requesting another code.',
    'otp_too_many_requests':
        'Too many code requests. Please try again in an hour.',
    'no_refresh_token': 'Your session ended. Please sign in again.',
    'refresh_failed':
        'We couldn\'t refresh your session. Please sign in again.',
    'session_revoked': 'Your session ended. Please sign in again.',
    'missing_authorization': 'Please sign in to continue.',
    'user_not_found': 'We couldn\'t find your account. Please sign in again.',
    'invalid_token': 'Your session isn\'t valid anymore. Please sign in again.',
    'wrong_token_type': 'Please sign in again to continue.',

    // Registration
    'npi_already_registered':
        'This NPI is already on Doqto. Sign in from the previous screen, or contact your admin.',
    'npi_invalid': 'NPI must be exactly 10 digits.',
    'phone_already_registered':
        'This number is already on another Doqto account. Use a different number, or sign out and sign in with this one.',
    'phone_not_verified': 'That number wasn\'t verified. Please send a new code.',
    'firebase_uid_mismatch': 'Your session changed. Please sign in again.',

    // Organizations
    'invalid_invite_code':
        'That invite code isn\'t recognised. Please check with your org admin.',
    'org_suspended':
        'Your organization is currently suspended. Contact support for assistance.',
    'org_not_found': 'We couldn\'t find that organization.',
    'member_not_found': 'That doctor isn\'t in this organization.',
    'not_an_org_member': 'You don\'t have access to this organization.',
    'super_admin_required':
        'This action is restricted to platform administrators.',
    'org_admin_required': 'Only an org admin can perform this action.',
    'user_not_in_any_org':
        'Join or create an organization before starting a chat.',

    // Conversations / messages
    'conversation_not_found': 'This conversation no longer exists.',
    'not_a_conversation_member': 'You\'re not part of this conversation.',
    'message_not_found': 'We couldn\'t find that message.',
    'rate_limited':
        'You\'re sending too quickly. Please wait a moment and try again.',
    'direct_requires_one_member':
        'Select one doctor to start a direct message.',
    'direct_requires_two_distinct': 'You can\'t start a chat with yourself.',
    'group_name_required': 'Please give the group a name.',

    // Files
    'file_too_large': 'That file is too large. Please send a file under 25 MB.',
    'voice_note_too_large':
        'That voice note is too long. Please record under 5 minutes.',
    'file_not_found': 'We couldn\'t find that attachment.',

    // Profile
    'avatar_too_large': 'Profile photos must be under 2 MB.',
    'avatar_unsupported_type': 'Please upload a JPG, PNG, or WEBP image.',
    'avatar_empty': 'That image looks empty. Please pick another one.',
    'skills_too_many': 'You can add up to 20 skills.',
    'skill_too_long': 'Each skill must be 40 characters or fewer.',

    // Scheduled messages
    'invalid_schedule_time': 'Pick a time at least a minute in the future.',
    'conversation_not_open':
        'You can\'t schedule messages in this conversation yet.',
  };

  /// Translate any thrown error into a physician-friendly single-line message.
  /// Safe to call with `null`, framework exceptions, or custom [ApiException]s.
  static String forApi(Object? err) {
    if (err is ApiException) {
      final mapped = _byCode[err.detail];
      if (mapped != null) return mapped;
      switch (err.status) {
        case 400:
          return 'We couldn\'t process that. Please double-check and try again.';
        case 401:
          return 'Please sign in to continue.';
        case 403:
          return 'You don\'t have permission to do that.';
        case 404:
          return 'We couldn\'t find what you were looking for.';
        case 413:
          return 'That attachment is too large.';
        case 429:
          return 'Too many requests — please slow down and try again.';
        case null:
          return 'Couldn\'t reach Doqto. Check your connection and try again.';
        default:
          return 'Something went wrong. Please try again.';
      }
    }
    if (err is TimeoutException) {
      return 'The request took too long. Check your connection.';
    }
    if (err is AuthBrokerException) return err.message;
    return 'Something went wrong. Please try again.';
  }
}
