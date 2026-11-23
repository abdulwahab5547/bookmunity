import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../firebase_options.dart';

class AuthController {
  final FirebaseAuth _auth = FirebaseAuth.instance;

  // LOGIN
  Future<User?> loginUser({
    required String email,
    required String password,
  }) async {
    try {
      UserCredential credential = await _auth.signInWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      return credential.user;
    } on FirebaseAuthException catch (e) {
      throw Exception(_getFirebaseError(e.code));
    }
  }

  // SIGNUP
  Future<User?> signupUser({
    required String email,
    required String password,
    String? displayName,
  }) async {
    try {
      UserCredential credential = await _auth.createUserWithEmailAndPassword(
        email: email.trim(),
        password: password.trim(),
      );

      final user = credential.user;
      if (user != null &&
          displayName != null &&
          displayName.trim().isNotEmpty) {
        await user.updateDisplayName(displayName.trim());
        await user.reload();
      }
      return _auth.currentUser;
    } on FirebaseAuthException catch (e) {
      throw Exception(_getFirebaseError(e.code));
    }
  }

  /// Google sign-in is offered on Android and iOS.
  static bool get googleSignInAvailable =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  static Future<void>? _googleReady;

  static Future<void> _initGoogle() => _googleReady ??= GoogleSignIn.instance
      .initialize(
        // iOS needs its OAuth client id; Android reads the web client id
        // that the google-services plugin generates from
        // google-services.json.
        clientId: defaultTargetPlatform == TargetPlatform.iOS
            ? DefaultFirebaseOptions.ios.iosClientId
            : null,
      )
      .catchError((Object error) {
        _googleReady = null;
        throw error;
      });

  /// Signs in with a Google account. Returns null if the user closed the
  /// account picker. New accounts get a profile through the username step
  /// in the auth gate, like email signups.
  Future<User?> signInWithGoogle() async {
    try {
      await _initGoogle();
      final account = await GoogleSignIn.instance.authenticate();
      final idToken = account.authentication.idToken;
      if (idToken == null) {
        throw Exception('Google did not return a sign-in token. Try again.');
      }
      final credential = await _auth.signInWithCredential(
        GoogleAuthProvider.credential(idToken: idToken),
      );
      return credential.user;
    } on GoogleSignInException catch (e) {
      if (e.code == GoogleSignInExceptionCode.canceled ||
          e.code == GoogleSignInExceptionCode.interrupted) {
        return null;
      }
      if (e.code == GoogleSignInExceptionCode.clientConfigurationError ||
          e.code == GoogleSignInExceptionCode.providerConfigurationError) {
        throw Exception(
          'Google sign-in is not set up for this app yet. Please use email '
          'for now.',
        );
      }
      throw Exception(
        'Google sign-in failed${e.description == null ? '' : ': ${e.description}'}',
      );
    } on FirebaseAuthException catch (e) {
      throw Exception(_getFirebaseError(e.code));
    }
  }

  // LOGOUT
  Future<void> logout() async {
    if (googleSignInAvailable && _googleReady != null) {
      // Forget the chosen account so the picker shows next time.
      try {
        await GoogleSignIn.instance.signOut();
      } catch (_) {}
    }
    await _auth.signOut();
  }

  Stream<User?> get authStateChanges => _auth.authStateChanges();

  Future<void> sendPasswordReset(String email) async {
    try {
      await _auth.sendPasswordResetEmail(email: email.trim());
    } on FirebaseAuthException catch (e) {
      throw Exception(_getFirebaseError(e.code));
    }
  }

  // CURRENT USER
  User? get currentUser => _auth.currentUser;

  // FIREBASE ERROR HANDLING
  String _getFirebaseError(String code) {
    switch (code) {
      case 'invalid-email':
        return 'Please enter a valid email address.';

      case 'user-not-found':
        return 'No account found with this email.';

      case 'wrong-password':
      case 'invalid-credential':
        return 'Incorrect email or password.';

      case 'email-already-in-use':
        return 'An account already exists with this email.';

      case 'weak-password':
        return 'Password should be at least 6 characters.';

      case 'user-disabled':
        return 'This account has been disabled.';

      case 'too-many-requests':
        return 'Too many attempts. Please try again later.';

      case 'account-exists-with-different-credential':
        return 'This email already has an account. Sign in with your '
            'password instead.';

      case 'operation-not-allowed':
        return 'This sign-in method is not enabled yet.';

      case 'network-request-failed':
        return 'Network error. Please check your internet connection.';

      default:
        return 'Something went wrong. Please try again.';
    }
  }
}
