// Physician-facing form validators. Single source of truth for every input
// rule in the app — both the rule AND the message live here, so changing a
// rule once propagates everywhere.
//
// Each validator returns null if the value is valid, or a short, calm,
// actionable error string otherwise.
//
// Voice matches `ErrorMessages`: lead with what's wrong, propose a fix, no
// jargon. Under ~80 chars so it fits one line under the input.

import 'package:phone_numbers_parser/phone_numbers_parser.dart';

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

  /// A single name part (first or last). [field] names it in the message.
  /// Registration collects the two halves separately so the NPI registry can
  /// be queried by first and last name.
  static Validator personName(String field) => (value) {
        final v = value.trim();
        final f = field.toLowerCase();
        if (v.isEmpty) return 'Please enter your $f.';
        if (v.length < 2) return 'Your $f must be at least 2 characters.';
        return null;
      };

  /// Invite code: 4 letters, middle dot, 4 digits (e.g. APOL·4827). 9 chars total.
  static Validator inviteCode() => (value) {
        final v = value.trim();
        if (v.isEmpty) return 'Please enter the invite code from your org admin.';
        if (v.length != 9) {
          return 'Invite codes are 9 characters (e.g. APOL·4827).';
        }
        if (!RegExp(r'^[A-Za-z]{4}·\d{4}$').hasMatch(v)) {
          return 'Invite code must be 4 letters, a dot, and 4 digits.';
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
