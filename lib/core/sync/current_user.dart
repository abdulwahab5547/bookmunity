import 'package:flutter_riverpod/flutter_riverpod.dart';

/// Uid of the signed-in account, or null when signed out or offline-only.
/// Everything per-account (the local database file, settings, sync) keys
/// off this. main.dart wires it to Firebase Auth; tests leave it null.
final currentUidProvider = Provider<String?>((ref) => null);
