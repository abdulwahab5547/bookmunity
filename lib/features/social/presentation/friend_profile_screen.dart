import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../../../design/formatters.dart';
import '../data/social_models.dart';
import '../data/social_providers.dart';
import 'my_profile_screen.dart';
import 'reader_profile.dart';
import 'user_avatar.dart';

/// Public profile of any reader: shelves, ratings, quotes, updates and
/// badges. Friends also see friends-only posts; others get an "Add friend"
/// action.
class FriendProfileScreen extends ConsumerWidget {
  const FriendProfileScreen({required this.uid, super.key});

  final String uid;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).valueOrNull;
    if (me != null && me.uid == uid) return const MyProfileScreen();

    final profile = ref.watch(profileProvider(uid));
    final friends = ref.watch(friendsProvider).valueOrNull ?? const <Friend>[];
    final isFriend = friends.any((friend) => friend.uid == uid);
    return Scaffold(
      appBar: BrutalAppBar(
        title: profile.valueOrNull?.displayName ?? 'Reader',
        actions: [
          if (isFriend)
            PopupMenuButton<String>(
              onSelected: (_) => _unfriend(context, ref),
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'remove', child: Text('Remove friend')),
              ],
            ),
        ],
      ),
      body: profile.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Profile unavailable',
          message: socialErrorMessage(error),
        ),
        data: (value) {
          if (value == null) {
            return const EmptyState(
              icon: Icons.person_off_outlined,
              title: 'This profile no longer exists',
            );
          }
          return ReaderProfileView(
            profile: value,
            action: !isFriend && me != null
                ? _FriendAction(me: me, other: value)
                : null,
          );
        },
      ),
    );
  }

  Future<void> _unfriend(BuildContext context, WidgetRef ref) async {
    final name =
        ref.read(profileProvider(uid)).valueOrNull?.displayName ??
        'this friend';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Remove $name?'),
        content: const Text(
          'You will no longer see each other’s friends-only posts. You can '
          'send a new '
          'request later.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await ref.read(socialRepositoryProvider)!.removeFriend(uid);
    } catch (error) {
      messenger.showSnackBar(
        SnackBar(content: Text(socialErrorMessage(error))),
      );
    }
  }
}

/// Add / pending / accept, depending on the request state between us.
class _FriendAction extends ConsumerWidget {
  const _FriendAction({required this.me, required this.other});

  final Profile me;
  final Profile other;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final outgoing =
        ref.watch(outgoingRequestsProvider).valueOrNull ??
        const <FriendRequest>[];
    final incoming =
        ref.watch(incomingRequestsProvider).valueOrNull ??
        const <FriendRequest>[];
    final sent = outgoing.where((r) => r.toUid == other.uid).firstOrNull;
    final received = incoming.where((r) => r.fromUid == other.uid).firstOrNull;
    final repository = ref.watch(socialRepositoryProvider)!;

    Future<void> run(Future<void> Function() action) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await action();
      } catch (error) {
        messenger.showSnackBar(
          SnackBar(content: Text(socialErrorMessage(error))),
        );
      }
    }

    if (received != null) {
      return BrutalPressable(
        onPressed: () => run(() => repository.acceptRequest(received, me: me)),
        backgroundColor: BrutalColors.green,
        child: const Center(child: Text('Accept friend request')),
      );
    }
    if (sent != null) {
      return OutlinedButton.icon(
        onPressed: () => run(() => repository.deleteRequest(sent)),
        icon: const Icon(Icons.hourglass_top, size: 18),
        label: const Text('Request sent · tap to cancel'),
      );
    }
    return BrutalPressable(
      onPressed: () => run(() => repository.sendRequest(me: me, to: other)),
      backgroundColor: BrutalColors.blue,
      foregroundColor: Colors.white,
      child: const Center(child: Text('Add friend')),
    );
  }
}

/// Avatar, names, bio and join date. Shared with [MyProfileScreen].
class ProfileHeader extends StatelessWidget {
  const ProfileHeader({required this.profile, this.avatar, super.key});

  final Profile profile;

  /// Replaces the plain avatar (the own-profile screen adds an edit badge).
  final Widget? avatar;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      children: [
        avatar ??
            UserAvatar(uid: profile.uid, hasPhoto: profile.hasPhoto, size: 96),
        const SizedBox(height: 12),
        Text(
          profile.displayName,
          style: theme.textTheme.titleLarge,
          textAlign: TextAlign.center,
        ),
        Text('@${profile.username}', style: theme.textTheme.bodySmall),
        if (profile.bio.isNotEmpty) ...[
          const SizedBox(height: 8),
          Text(
            profile.bio,
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium,
          ),
        ],
        if (profile.createdAt != null) ...[
          const SizedBox(height: 6),
          Text(
            'Reading on Bookmunity since ${formatDate(profile.createdAt!)}',
            style: theme.textTheme.labelSmall,
          ),
        ],
      ],
    );
  }
}
