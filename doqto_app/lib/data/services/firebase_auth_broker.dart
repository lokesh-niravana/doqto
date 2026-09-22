import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_facebook_auth/flutter_facebook_auth.dart';
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
        if (!completer.isCompleted) completer.completeError(e);
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
    return _idTokenFor(await _auth.signInWithCredential(credential));
  }

  @override
  Future<String> linkPhone(PhoneChallenge challenge, String code) async {
    final user = _auth.currentUser;
    if (user == null) throw FirebaseAuthException(code: 'no-current-user');
    final credential = PhoneAuthProvider.credential(
      verificationId: challenge.verificationId,
      smsCode: code,
    );
    await user.linkWithCredential(credential);
    // Force a refresh: the phone_number claim only appears in a token minted
    // after the link.
    final token = await user.getIdToken(true);
    if (token == null) throw FirebaseAuthException(code: 'no-id-token');
    return token;
  }

  @override
  Future<String?> signInWithSocial(SocialProvider provider) async {
    // Apple is the odd one out: Firebase drives that flow end to end, so it
    // signs in directly rather than handing back a credential.
    if (provider == SocialProvider.apple) {
      final apple = AppleAuthProvider()
        ..addScope('email')
        ..addScope('name');
      return _idTokenFor(await _auth.signInWithProvider(apple));
    }
    final credential = provider == SocialProvider.google
        ? await _googleCredential()
        : await _facebookCredential();
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

  Future<AuthCredential?> _facebookCredential() async {
    final result = await FacebookAuth.instance.login();
    if (result.status != LoginStatus.success) return null;
    return FacebookAuthProvider.credential(result.accessToken!.tokenString);
  }

  Future<String> _idTokenFor(UserCredential result) async {
    final token = await result.user?.getIdToken();
    if (token == null) throw FirebaseAuthException(code: 'no-id-token');
    return token;
  }

  @override
  Future<void> signOut() => _auth.signOut();
}
