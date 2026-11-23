import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/social_models.dart';
import '../data/social_providers.dart';
import 'choose_username_screen.dart';
import 'friend_profile_screen.dart';
import 'my_profile_screen.dart';
import 'user_avatar.dart';

class FriendsScreen extends ConsumerWidget {
  const FriendsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(socialRepositoryProvider) == null) {
      return Scaffold(
        appBar: const BrutalAppBar(title: 'Friends'),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Sign in to use friends',
          message: ref.watch(firebaseReadyProvider)
              ? 'Friends, activity and reviews need a Bookmunity account.'
              : 'Friends are not available on this platform.',
        ),
      );
    }
    final profile = ref.watch(myProfileProvider);
    return profile.when(
      loading: () => const Scaffold(
        appBar: BrutalAppBar(title: 'Friends'),
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: const BrutalAppBar(title: 'Friends'),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Friends are unavailable',
          message: socialErrorMessage(error),
        ),
      ),
      data: (me) =>
          me == null ? const ChooseUsernameScreen() : _FriendsHome(me: me),
    );
  }
}

// ------------------------------------------------------------------ home

class _FriendsHome extends ConsumerWidget {
  const _FriendsHome({required this.me});

  final Profile me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming =
        ref.watch(incomingRequestsProvider).valueOrNull ?? const [];
    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: BrutalAppBar(
          title: 'Friends',
          actions: [
            IconButton(
              tooltip: 'My profile',
              onPressed: () => Navigator.of(context).push(
                MaterialPageRoute(builder: (_) => const MyProfileScreen()),
              ),
              icon: UserAvatar(uid: me.uid, hasPhoto: me.hasPhoto, size: 30),
            ),
            IconButton(
              tooltip: 'Add a friend',
              icon: const Icon(Icons.person_add_alt),
              onPressed: () => _showSearch(context, me),
            ),
          ],
          bottom: TabBar(
            tabs: [
              const Tab(text: 'Friends'),
              Tab(
                child: Badge(
                  isLabelVisible: incoming.isNotEmpty,
                  label: Text('${incoming.length}'),
                  child: const Text('Requests'),
                ),
              ),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            _FriendsTab(me: me),
            _RequestsTab(me: me),
          ],
        ),
      ),
    );
  }
}

class _FriendsTab extends ConsumerWidget {
  const _FriendsTab({required this.me});

  final Profile me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final friends = ref.watch(friendsProvider);
    return friends.when(
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (error, _) => EmptyState(
        icon: Icons.cloud_off_outlined,
        title: 'Friends could not be loaded',
        message: socialErrorMessage(error),
      ),
      data: (items) => items.isEmpty
          ? EmptyState(
              icon: Icons.people_outline,
              title: 'No friends yet',
              message:
                  'You are @${me.username}. Search for a friend’s username to connect.',
              action: BrutalPressable(
                onPressed: () => _showSearch(context, me),
                child: const Text('Find friends'),
              ),
            )
          : ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: items.length,
              itemBuilder: (context, index) {
                final friend = items[index];
                return ListTile(
                  leading: UserAvatar(uid: friend.uid),
                  title: Text(friend.displayName),
                  subtitle: Text('@${friend.username}'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => _openProfile(context, friend.uid),
                );
              },
            ),
    );
  }
}

class _RequestsTab extends ConsumerWidget {
  const _RequestsTab({required this.me});

  final Profile me;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming =
        ref.watch(incomingRequestsProvider).valueOrNull ?? const [];
    final outgoing =
        ref.watch(outgoingRequestsProvider).valueOrNull ?? const [];
    final repository = ref.watch(socialRepositoryProvider)!;
    if (incoming.isEmpty && outgoing.isEmpty) {
      return const EmptyState(
        icon: Icons.mark_email_unread_outlined,
        title: 'No pending requests',
      );
    }
    Future<void> run(
      BuildContext context,
      Future<void> Function() action,
    ) async {
      final messenger = ScaffoldMessenger.of(context);
      try {
        await action();
      } catch (error) {
        messenger.showSnackBar(
          SnackBar(content: Text(socialErrorMessage(error))),
        );
      }
    }

    return ListView(
      padding: const EdgeInsets.symmetric(vertical: 8),
      children: [
        if (incoming.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 8, 16, 4),
            child: SectionLabel('Received'),
          ),
          for (final request in incoming)
            ListTile(
              leading: UserAvatar(uid: request.fromUid),
              onTap: () => _openProfile(context, request.fromUid),
              title: Text(request.fromDisplayName),
              subtitle: Text('@${request.fromUsername}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: 'Decline',
                    icon: const Icon(Icons.close),
                    onPressed: () =>
                        run(context, () => repository.deleteRequest(request)),
                  ),
                  IconButton.filled(
                    tooltip: 'Accept',
                    style: IconButton.styleFrom(
                      backgroundColor: BrutalColors.green,
                    ),
                    icon: const Icon(Icons.check, color: Colors.white),
                    onPressed: () => run(
                      context,
                      () => repository.acceptRequest(request, me: me),
                    ),
                  ),
                ],
              ),
            ),
        ],
        if (outgoing.isNotEmpty) ...[
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: SectionLabel('Sent'),
          ),
          for (final request in outgoing)
            ListTile(
              leading: UserAvatar(uid: request.toUid),
              onTap: () => _openProfile(context, request.toUid),
              title: Text(request.toDisplayName),
              subtitle: Text('@${request.toUsername} · waiting'),
              trailing: TextButton(
                onPressed: () =>
                    run(context, () => repository.deleteRequest(request)),
                child: const Text('Cancel'),
              ),
            ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------- search

void _showSearch(BuildContext context, Profile me) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    builder: (context) => Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SizedBox(
        height: MediaQuery.sizeOf(context).height * 0.75,
        child: _UserSearch(me: me),
      ),
    ),
  );
}

class _UserSearch extends ConsumerStatefulWidget {
  const _UserSearch({required this.me});

  final Profile me;

  @override
  ConsumerState<_UserSearch> createState() => _UserSearchState();
}

class _UserSearchState extends ConsumerState<_UserSearch> {
  List<Profile> _results = const [];
  bool _searching = false;
  String? _error;
  String _query = '';

  Future<void> _search(String value) async {
    final query = value.trim();
    setState(() => _query = query);
    if (query.isEmpty) {
      setState(() => _results = const []);
      return;
    }
    setState(() {
      _searching = true;
      _error = null;
    });
    try {
      final results = await ref
          .read(socialRepositoryProvider)!
          .searchUsers(query);
      if (mounted && query == _query) setState(() => _results = results);
    } catch (error) {
      if (mounted) setState(() => _error = socialErrorMessage(error));
    } finally {
      if (mounted) setState(() => _searching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final friends = {
      for (final friend
          in ref.watch(friendsProvider).valueOrNull ?? const <Friend>[])
        friend.uid,
    };
    final sent = {
      for (final request
          in ref.watch(outgoingRequestsProvider).valueOrNull ??
              const <FriendRequest>[])
        request.toUid,
    };
    final received = {
      for (final request
          in ref.watch(incomingRequestsProvider).valueOrNull ??
              const <FriendRequest>[])
        request.fromUid,
    };
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            autocorrect: false,
            onChanged: _search,
            decoration: const InputDecoration(
              hintText: 'Search by username',
              prefixIcon: Icon(Icons.alternate_email),
            ),
          ),
        ),
        if (_searching) const LinearProgressIndicator(),
        if (_error != null)
          Padding(padding: const EdgeInsets.all(16), child: Text(_error!)),
        Expanded(
          child: _query.isNotEmpty && !_searching && _results.isEmpty
              ? const EmptyState(
                  icon: Icons.person_search_outlined,
                  title: 'No one found',
                  message: 'Check the spelling of the username.',
                )
              : ListView.builder(
                  itemCount: _results.length,
                  itemBuilder: (context, index) {
                    final profile = _results[index];
                    final Widget trailing;
                    if (friends.contains(profile.uid)) {
                      trailing = const Text('Friends');
                    } else if (sent.contains(profile.uid)) {
                      trailing = const Text('Requested');
                    } else if (received.contains(profile.uid)) {
                      trailing = const Text('Wants to connect');
                    } else {
                      trailing = TextButton(
                        onPressed: () async {
                          final messenger = ScaffoldMessenger.of(context);
                          try {
                            await ref
                                .read(socialRepositoryProvider)!
                                .sendRequest(me: widget.me, to: profile);
                          } catch (error) {
                            messenger.showSnackBar(
                              SnackBar(
                                content: Text(socialErrorMessage(error)),
                              ),
                            );
                          }
                        },
                        child: const Text('Add'),
                      );
                    }
                    return ListTile(
                      onTap: () => _openProfile(context, profile.uid),
                      leading: UserAvatar(
                        uid: profile.uid,
                        hasPhoto: profile.hasPhoto,
                      ),
                      title: Text(profile.displayName),
                      subtitle: Text('@${profile.username}'),
                      trailing: trailing,
                    );
                  },
                ),
        ),
      ],
    );
  }
}

void _openProfile(BuildContext context, String uid) {
  Navigator.of(
    context,
  ).push(MaterialPageRoute(builder: (_) => FriendProfileScreen(uid: uid)));
}
