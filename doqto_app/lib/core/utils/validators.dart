// Physician-facing form validators. Single source of truth for every input
// rule in the app — both the rule AND the message live here, so changing a
// rule once propagates everywhere.
//
// Each validator returns null if the value is valid, or a short, calm,
// actionable error string otherwise.
//
// Voice matches `ErrorMessages`: lead with what's wrong, propose a fix, no
// jargon. Under ~80 chars so it fits one line under the input.

import 'package:flutter/services.dart';
import 'package:phone_numbers_parser/phone_numbers_parser.dart';
import '../constants/strings.dart';

typedef Validator = String? Function(String value);

class Validators {
  Validators._();

  // ---------- Building blocks ----------

  static Validator required([String? field]) => (value) {
        if (value.trim().isEmpty) {
          return field == null
              ? 'This field is required.'
              : 'Please enter your ${field.toLowerCase()}.';
        }
        return null;
      };

  static Validator minLength(int n, [String? field]) => (value) {
        if (value.trim().length < n) {
          return 'Must be at least $n characters.';
        }
        return null;
      };

  static Validator exactDigits(int n, String field) => (value) {
        final digits = value.replaceAll(RegExp(r'\D'), '');
        if (digits.isEmpty) return 'Please enter your $field.';
        if (digits.length != n) {
          return '$field must be exactly $n digits (you entered ${digits.length}).';
        }
        return null;
      };

  /// Compose multiple validators; returns the first non-null error.
  static Validator compose(List<Validator> validators) => (value) {
        for (final v in validators) {
          final result = v(value);
          if (result != null) return result;
        }
        return null;
      };

  // ---------- Domain validators ----------

  /// NPI: 10 digits. Per https://nppes.cms.hhs.gov — we don't validate the
  /// Luhn check-digit in MVP (backend re-verifies against CMS later).
  static Validator npi() => (value) {
        final v = value.trim();
        if (v.isEmpty) return 'Please enter your NPI number.';
        if (!RegExp(r'^\d+$').hasMatch(v)) {
          return 'NPI must be digits only.';
        }
        if (v.length != 10) {
          return 'NPI must be exactly 10 digits (you entered ${v.length}).';
        }
        return null;
      };

  /// Phone: full E.164 (`+<country><national>`). Uses libphonenumber-equivalent
  /// parsing so each country's length and format rules are enforced (e.g. India
  /// mobiles must be 10 digits starting 6-9, US numbers are exactly 10 etc.).
  static Validator phone() => (value) {
        final v = value.trim();
        if (v.isEmpty) return 'Please enter your phone number.';
        if (!v.startsWith('+')) {
          return 'Please pick a country and enter your phone number.';
        }
        try {
          final parsed = PhoneNumber.parse(v);
          if (!parsed.isValid()) {
            return 'That doesn\'t look like a valid number for ${parsed.isoCode.name}.';
          }
        } catch (_) {
          return 'Please enter a valid phone number.';
        }
        return null;
      };

  /// National-only phone validator for use with a separate country selector.
  /// Pass the ISO 3166 country code (e.g. `US`, `IN`) that the user picked.
  static Validator phoneForCountry(String isoCode) => (value) {
        final digits = value.replaceAll(RegExp(r'\D'), '');
        if (digits.isEmpty) return 'Please enter your phone number.';
        try {
          final parsed = PhoneNumber.parse(digits, destinationCountry: IsoCode.values.byName(isoCode));
          if (!parsed.isValid()) {
            return 'That doesn\'t look like a valid $isoCode number.';
          }
        } catch (_) {
          return 'Please enter a valid phone number.';
        }
        return null;
      };

  /// Email: one @, a dot in the domain, no spaces. Deliberately permissive —
  /// the only authority on whether an address exists is a mail server.
  static Validator email() => (value) {
        final v = value.trim();
        if (v.isEmpty) return 'Please enter your email address.';
        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]{2,}$').hasMatch(v)) {
          return 'That doesn\'t look like an email address.';
        }
        return null;
      };

  /// OTP: exactly N digits.
  static Validator otp(int length) => (value) {
        final v = value.trim();
        if (v.isEmpty) return 'Please enter the code we sent you.';
        if (!RegExp(r'^\d+$').hasMatch(v)) return 'Code must be digits only.';
        if (v.length != length) {
          return 'Code must be $length digits (you entered ${v.length}).';
        }
        return null;
      };

  /// A PIN the user chose (two-step verification), not a code we sent: the
  /// message says so. One message for empty, short and non-digit input.
  static Validator pin(int length) => (value) {
        final v = value.trim();
        if (v.length != length || !RegExp(r'^\d+$').hasMatch(v)) {
          return Strings.pinInvalid(length);
        }
        return null;
      };

  /// A single name part (first or last). [field] names it in the message.
  /// Registration collects the two halves separately so the NPI registry can
  /// be queried by first and last name.
  static Validator personName(String field) => (value) {
        final v = value.trim();
        final f = field.toLowerCase();
        if (v.isEmpty) return 'Please enter your $f.';
        return null;
      };

  /// Canonical invite code as the server issues and compares it: four
  /// upper-case letters, a middle dot, four digits (`APOL·4827`). Whatever
  /// separator was typed (`.`, `-`, space, `·`, or none) is dropped and the
  /// middle dot re-inserted after the fourth character.
  static String normalizeInviteCode(String value) {
    final raw = value.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');
    final v = raw.length > 8 ? raw.substring(0, 8) : raw;
    if (v.length <= 4) return v;
    return '${v.substring(0, 4)}·${v.substring(4)}';
  }

  /// Invite code: 4 letters then 4 digits (e.g. APOL·4827). The middle dot
  /// cannot be typed on a phone keyboard, so it is never required of the
  /// user — see [normalizeInviteCode] and [InviteCodeFormatter].
  static Validator inviteCode() => (value) {
        final v = normalizeInviteCode(value);
        if (v.isEmpty) return 'Please enter the invite code from your org admin.';
        if (v.length != 9) {
          return 'Invite codes are 4 letters and 4 digits (e.g. APOL·4827).';
        }
        if (!RegExp(r'^[A-Z]{4}·\d{4}$').hasMatch(v)) {
          return 'Invite codes are 4 letters followed by 4 digits (e.g. APOL·4827).';
        }
        return null;
      };

  /// Org name: 1–255 chars, trimmed.
  static Validator orgName() => (value) {
        final v = value.trim();
        if (v.isEmpty) return 'Please name your organization.';
        if (v.length > 255) return 'Organization name is too long.';
        return null;
      };
}

/// Formats an invite code as it is typed: upper-cases, drops any separator
/// the user typed (`.`, `-`, space, `·`) and puts the middle dot back after
/// the fourth character, so `apol4827` becomes `APOL·4827`. Nine characters
/// at most.
class InviteCodeFormatter extends TextInputFormatter {
  const InviteCodeFormatter();

  @override
  TextEditingValue formatEditUpdate(TextEditingValue oldValue, TextEditingValue newValue) {
    final text = Validators.normalizeInviteCode(newValue.text);
    if (text == newValue.text) return newValue;
    // Keep the caret after the same number of code characters it followed.
    final end = newValue.selection.end;
    var offset = text.length;
    if (end >= 0 && end < newValue.text.length) {
      final before = Validators.normalizeInviteCode(newValue.text.substring(0, end)).replaceAll('·', '').length;
      offset = before > 4 ? before + 1 : before;
      if (offset > text.length) offset = text.length;
    }
    return TextEditingValue(text: text, selection: TextSelection.collapsed(offset: offset));
  }
}
