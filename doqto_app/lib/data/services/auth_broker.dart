/// Firebase sits behind this interface so the rest of the app — and every
/// widget test — never touches a Firebase binding.
///
/// Phone, Google, Facebook and Apple all converge on the same thing: a Firebase
/// ID token, which [AuthRepository.signInWithFirebase] exchanges for a Doqto
/// session. Nothing downstream knows which button was tapped.
///
/// Why phone auth moved here: SNS cannot reach US numbers from our AWS account
/// (no origination identity) and Twilio Verify is gated on a TrustHub review.
/// Firebase sends through Google's own carrier relationships, so neither gate
/// applies. See docs/superpowers/specs/2026-09-14-firebase-auth-design.md.
library;

enum SocialProvider { google, facebook, apple }

/// A phone verification in flight. [verificationId] is Firebase's handle for
/// the SMS it just sent; it is meaningless to us beyond passing it back.
class PhoneChallenge {
  const PhoneChallenge(this.verificationId, this.phone);
  final String verificationId;
  final String phone;
}

abstract class AuthBroker {
  /// Sends the SMS. Throws if Firebase refuses (bad number, quota, no network).
  Future<PhoneChallenge> startPhoneSignIn(String phone);

  /// Returns the Firebase ID token for a correct code. Throws on a wrong one.
  Future<String> confirmPhoneCode(PhoneChallenge challenge, String code);

  /// Attach a verified phone to the CURRENT Firebase user and return the
  /// refreshed ID token, whose phone_number claim proves the SMS was answered.
  ///
  /// Not a sign-in: signing in with a phone signs you in *as* whoever owns it,
  /// which mid-registration would swap accounts.
  Future<String> linkPhone(PhoneChallenge challenge, String code);

  /// Returns the ID token, or null when the user dismissed the provider sheet.
  /// Cancellation is a normal outcome, not an error.
  Future<String?> signInWithSocial(SocialProvider provider);

  Future<void> signOut();
}

/// Test double. Lives in lib/ rather than test/ because widget tests across
/// several suites need it and it is the only way to run the app without a
/// Firebase binding.
class FakeAuthBroker implements AuthBroker {
  FakeAuthBroker({this.idToken = 'fake-id-token'});

  /// null means "user cancelled".
  final String? idToken;
  final List<String> startedFor = [];

  @override
  Future<PhoneChallenge> startPhoneSignIn(String phone) async {
    startedFor.add(phone);
    return PhoneChallenge('fake-verification-id', phone);
  }

  @override
  Future<String> confirmPhoneCode(PhoneChallenge challenge, String code) async {
    final t = idToken;
    if (t == null) throw StateError('no token');
    return t;
  }

  @override
  Future<String> linkPhone(PhoneChallenge challenge, String code) async {
    final t = idToken;
    if (t == null) throw StateError('no token');
    return t;
  }

  @override
  Future<String?> signInWithSocial(SocialProvider provider) async => idToken;

  @override
  Future<void> signOut() async {}
}
