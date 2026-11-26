import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_sign_in/google_sign_in.dart';

import 'auth_broker.dart';

/// The real [AuthBroker]. Everything Firebase-specific lives here and nowhere
/// else, so no other file — and no widget test — needs a Firebase binding.
class FirebaseAuthBroker implements AuthBroker {
  FirebaseAuthBroker({FirebaseAuth? auth}) : _auth = auth ?? FirebaseAuth.instance;

  final FirebaseAuth _auth;

  @override
  SocialProfile? get profile {
    final u = _auth.currentUser;
    return u == null ? null : (name: u.displayName, email: u.email);
  }

  @override
  Future<PhoneChallenge> startPhoneSignIn(String phone) async {
    // verifyPhoneNumber is callback-based; this adapts it to a Future so the
    // UI can await "the SMS is on its way" like any other call.
    final completer = Completer<PhoneChallenge>();
    await _auth.verifyPhoneNumber(
      phoneNumber: phone,
      verificationCompleted: (_) {
        // Android instant verification. We ignore it deliberately: the user is
        // already looking at the code screen, and the SMS still arrives. Taking
        // this path would sign them in mid-keystroke.
      },
      verificationFailed: (e) {
        if (!completer.isCompleted) completer.completeError(_plain(e));
      },
      codeSent: (verificationId, _) {
        if (!completer.isCompleted) {
          completer.complete(PhoneChallenge(verificationId, phone));
        }
      },
      codeAutoRetrievalTimeout: (_) {},
    );
    return completer.future;
  }

  @override
  Future<String> confirmPhoneCode(PhoneChallenge challenge, String code) async {
    final credential = PhoneAuthProvider.credential(
      verificationId: challenge.verificationId,
      smsCode: code,
    );
    try {
      return _idTokenFor(await _auth.signInWithCredential(credential));
    } on FirebaseAuthException catch (e) {
      throw _plain(e);
    }
  }

  @override
  Future<String> linkPhone(PhoneChallenge challenge, String code) async {
    final user = _auth.currentUser;
    if (user == null) throw FirebaseAuthException(code: 'no-current-user');
    final credential = PhoneAuthProvider.credential(
      verificationId: challenge.verificationId,
      smsCode: code,
    );
    try {
      // A login holds at most one phone. If one is already attached (a stale
      // link from an earlier refused attempt, or a number being changed),
      // replace it; linking again fails with provider-already-linked.
      final hasPhone = user.providerData
          .any((p) => p.providerId == PhoneAuthProvider.PROVIDER_ID);
      if (hasPhone) {
        await user.updatePhoneNumber(credential);
      } else {
        await user.linkWithCredential(credential);
      }
    } on FirebaseAuthException catch (e) {
      throw _plain(e);
    }
    // Force a refresh: the phone_number claim only appears in a token minted
    // after the link.
    final token = await user.getIdToken(true);
    if (token == null) throw FirebaseAuthException(code: 'no-id-token');
    return token;
  }

  @override
  Future<void> unlinkPhone() async {
    final user = _auth.currentUser;
    if (user == null) return;
    if (!user.providerData.any((p) => p.providerId == PhoneAuthProvider.PROVIDER_ID)) {
      return;
    }
    await user.unlink(PhoneAuthProvider.PROVIDER_ID);
  }

  @override
  Future<String?> signInWithSocial(SocialProvider provider) async {
    // Apple is the odd one out: Firebase drives that flow end to end, so it
    // signs in directly rather than handing back a credential.
    if (provider == SocialProvider.apple) {
      final apple = AppleAuthProvider()
        ..addScope('email')
        ..addScope('name');
      try {
        return _idTokenFor(await _auth.signInWithProvider(apple));
      } on FirebaseAuthException catch (e) {
        // Dismissing Apple's sheet is a choice, not a failure.
        if (e.code == _appleCanceled) return null;
        throw _plain(e);
      }
    }
    final credential = await _googleCredential();
    // null means the user dismissed the sheet — a normal outcome, not an error.
    if (credential == null) return null;
    return _idTokenFor(await _auth.signInWithCredential(credential));
  }

  // google_sign_in 7 must be initialized exactly once before any other call.
  // No arguments: iOS reads CLIENT_ID from GoogleService-Info.plist, Android
  // reads default_web_client_id generated from google-services.json.
  Future<void>? _googleReady;

  Future<AuthCredential?> _googleCredential() async {
    await (_googleReady ??= GoogleSignIn.instance.initialize());
    try {
      final account = await GoogleSignIn.instance.authenticate();
      return GoogleAuthProvider.credential(
        idToken: account.authentication.idToken,
      );
    } on GoogleSignInException catch (e) {
      // v7 throws on a dismissed sheet rather than returning null.
      if (e.code == GoogleSignInExceptionCode.canceled) return null;
      rethrow;
    }
  }

  /// Nothing outside this file may see a FirebaseAuthException.
  AuthBrokerException _plain(FirebaseAuthException e) =>
      AuthBrokerException(e.code, e.message ?? e.code);

  Future<String> _idTokenFor(UserCredential result) async {
    _appleMismatch = false; // a fresh sign-in clears the refusal
    final token = await result.user?.getIdToken();
    if (token == null) throw FirebaseAuthException(code: 'no-id-token');
    return token;
  }

  /// What the iOS plugin reports for ASAuthorizationError.canceled.
  static const _appleCanceled = 'canceled';
  static const _appleProviderId = 'apple.com';
  bool _appleMismatch = false;

  @override
  Future<bool> revokeAppleAccess() async {
    final user = _auth.currentUser;
    // After a mismatch the Firebase session is gone, so "nobody signed in"
    // must not be read as "nothing to revoke": refuse until a fresh sign-in.
    if (_appleMismatch) {
      throw const AuthBrokerException(
        'apple-account-mismatch',
        'Sign out and sign in again with your own Apple ID to delete this account.',
      );
    }
    if (user == null) return true;
    if (!user.providerData.any((p) => p.providerId == _appleProviderId)) {
      return true;
    }
    try {
      // Apple only issues an authorization code during an authorization, so
      // the person confirms with Face ID / passcode once more. The same step
      // makes the Firebase sign-in recent enough for [deleteIdentity].
      //
      // signInWithProvider, not reauthenticateWithProvider: on iOS the
      // plugin's reauthenticate path leaves an internal flag set when the
      // sheet is dismissed, and the next "Continue with Apple" then never
      // completes. Signing in again as the same person has the same effect
      // and returns the same authorization code.
      final result = await _auth.signInWithProvider(AppleAuthProvider());
      if (result.user?.uid != user.uid) {
        // A different Apple ID was used: that is not this account's consent.
        _appleMismatch = true;
        await _auth.signOut();
        throw const AuthBrokerException(
          'apple-account-mismatch',
          'That Apple ID does not match this account. Sign in again to delete it.',
        );
      }
      final code = result.additionalUserInfo?.authorizationCode;
      if (code == null || code.isEmpty) {
        throw const AuthBrokerException(
          'no-authorization-code',
          'Apple did not confirm the request. Try again.',
        );
      }
      await _auth.revokeTokenWithAuthorizationCode(code);
      return true;
    } on FirebaseAuthException catch (e) {
      if (e.code == _appleCanceled) return false;
      throw _plain(e);
    }
  }

  @override
  Future<void> deleteIdentity() async {
    try {
      await _auth.currentUser?.delete();
    } on FirebaseAuthException {
      // requires-recent-login and friends: see the interface comment.
    }
  }

  @override
  Future<void> signOut() => _auth.signOut();
}
