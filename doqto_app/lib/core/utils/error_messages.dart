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
        'Messages can only be edited within 15 minutes of sending.',
    'delete_window_closed':
        'Messages can only be deleted for everyone within 48 hours of sending.',
    'message_deleted': 'This message was already deleted.',
    'not_message_sender': 'You can only change your own messages.',
    // Message features (batch 4)
    'reply_target_invalid': 'That message can\'t be replied to any more.',
    'forward_limit': 'This message has been forwarded too many times.',
    'forward_blocked_by_org':
        'Your organization doesn\'t allow forwarding messages outside it.',
    'message_not_forwardable': 'This message can\'t be forwarded.',
    'message_not_starrable': 'This message can\'t be starred.',
    'message_not_pinnable': 'This message can\'t be pinned.',
    'invalid_pin_duration': 'Pick 24 hours, 7 days or 30 days.',
    'mention_not_member': 'You can only mention people in this chat.',
    'too_many_mentions': 'That\'s too many mentions for one message.',
    'link_previews_disabled': 'Link previews are off in your privacy settings.',
    'invalid_url': 'That link doesn\'t look right.',
    'url_not_allowed': 'That link can\'t be previewed.',
    'too_large': 'That page is too large to preview.',
    'fetch_failed': 'We couldn\'t reach that link.',
    'not_html': 'That link has nothing to preview.',
    'report_not_found': 'We couldn\'t find that report.',
    // Compliance (batch 7)
    'reason_required': 'Please give a reason for the request.',
    'access_request_pending_exists':
        'A request for this conversation is already waiting for a decision.',
    'access_request_not_found': 'We couldn\'t find that access request.',
    'access_request_not_pending': 'That request has already been decided.',
    'self_approval_forbidden':
        'A different admin has to approve your own request.',
    'not_requester': 'Only the admin who asked can open this view.',
    'access_request_not_approved': 'This request hasn\'t been approved.',
    'access_request_expired': 'The 24-hour access window has ended.',
    'scheduled_message_not_found': 'That scheduled message is gone already.',
    'retention_days_invalid': 'Retention must be between 1 and 3650 days.',
    'default_disappear_sec_invalid': 'Pick one of the listed timers.',
    'before_and_before_date_exclusive': 'Pick one date to jump to.',
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
    // Settings (batch 6)
    'tone_invalid': 'That tone isn\'t available. Pick another one.',
    'session_not_found': 'That device is already signed out.',
    'pin_invalid': 'That PIN doesn\'t match. Try again.',
    'pin_not_set': 'Two-step verification isn\'t turned on.',
    'pin_required': 'Enter your two-step PIN to continue.',
    'pin_too_many_attempts':
        'Too many PIN attempts. Please wait 15 minutes and try again.',
    'status_text_too_long': 'Keep your status under 40 characters.',
    'status_preset_or_text': 'Pick a preset or write your own status, not both.',
    'invalid_status_expiry': 'Pick 1 hour, 8 hours, 24 hours or never.',
    'export_failed': 'We couldn\'t prepare your export. Try again later.',
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
    'org_pending_exists':
        'You already have an organization waiting for verification.',
    'org_exists':
        'That practice is already on Doqto. Ask a member for the invite code.',
    'npi_not_listed':
        'Your NPI isn\'t listed with that practice. Ask a member for the invite code.',
    'org_not_verified': 'Groups open once your organization is verified.',
    'directory_entry_not_found':
        'We couldn\'t find that practice. Enter it yourself instead.',
    'user_not_in_any_org':
        'Group chats need an organization. Join or create one first.',
    'user_unavailable': 'This doctor can\'t be messaged right now.',
    'not_reachable': 'This doctor isn\'t accepting messages right now.',
    'network_dm_disabled':
        'Messaging doctors outside your organization isn\'t available yet.',

    // Conversations / messages
    'conversation_not_found': 'This conversation no longer exists.',
    // Conversation preferences (batch 3)
    'pin_limit': 'You can pin up to 3 chats. Unpin one first.',
    'delete_group_use_leave': 'Leave the group to remove it from your chats.',
    'not_a_conversation_member': 'You\'re not part of this conversation.',
    'message_not_found': 'We couldn\'t find that message.',
    'rate_limited':
        'You\'re sending too quickly. Please wait a moment and try again.',
    'direct_requires_one_member':
        'Select one doctor to start a direct message.',
    'direct_requires_two_distinct': 'You can\'t start a chat with yourself.',
    'group_name_required': 'Please give the group a name.',

    // Files
    'file_too_large': 'That file is too large. Please send a file under 100 MB.',
    // Media (batch 5)
    'caption_too_long': 'Captions can be up to 1,024 characters.',
    'thumb_too_large': 'The video preview is too large. Please try again.',
    'thumb_not_allowed': 'Only videos carry a preview image.',
    'video_too_long': 'Videos can be up to 10 minutes long.',
    'waveform_invalid': 'We couldn\'t read that voice note. Please record it again.',
    'upload_intent_not_found': 'That upload is no longer valid. Please send it again.',
    'upload_intent_expired': 'That upload took too long. Please send it again.',
    'upload_parts_invalid': 'The upload didn\'t complete. Please send it again.',
    'upload_missing': 'The file didn\'t reach the server. Please send it again.',
    'upload_put_failed': 'The upload was interrupted. Check your connection and try again.',
    'media_export_blocked': 'Your organization doesn\'t allow saving or sharing media.',
    'invalid_media_type': 'That isn\'t something the gallery can show.',
    'invalid_cursor': 'Pull to refresh and try again.',
    'not_a_poll': 'That message isn\'t a poll.',
    'poll_single_choice': 'This poll takes one answer.',
    'poll_option_invalid': 'That answer isn\'t part of this poll any more.',
    'poll_question_required': 'Give the poll a question.',
    'poll_options_count': 'A poll needs between 2 and 12 answers.',
    'poll_options_duplicate': 'Each answer must be different.',
    'poll_option_empty': 'Answers can\'t be blank.',
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

    // Voice notes
    'voice_note_duration':
        'Voice notes must be between 1 second and 5 minutes long.',

    // Groups
    'post_restricted': 'Only admins can send messages in this group.',
    'group_full': 'This group is full (256 members). Remove someone to invite more.',
    'group_not_found': 'This group isn\'t available.',
    'not_a_group_member': 'You\'re not a member of this group.',
    'not_invitable':
        'You can only invite connections and colleagues from your organization.',
    'already_a_member': 'They\'re already in this group.',
    'cannot_invite_self': 'You\'re already in this group.',
    'invite_not_found': 'This invite is no longer valid.',
    'invite_not_pending': 'This invite was already answered.',
    'invite_expired': 'This invite link has expired. Ask for a new one.',
    'invite_exhausted': 'This invite link has been used up. Ask for a new one.',
    'not_authorized': 'Only group admins can do that.',
    'owner_only': 'Only the group owner can do that.',
    'owner_must_transfer':
        'Transfer ownership to another member before leaving the group.',
    'cannot_change_owner_role': 'The owner\'s role can\'t be changed.',
    'use_transfer_ownership': 'Use "Transfer ownership" to make someone the owner.',
    'cannot_ban_self': 'You can\'t ban yourself.',
    'already_owner': 'You already own this group.',
    'group_owner_limit': 'You own the maximum number of groups.',
    'group_dm_disabled':
        'This group doesn\'t allow direct messages between members.',
    'group_dm_request':
        'Connect with this doctor first — this group only allows direct messages between connections.',
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
