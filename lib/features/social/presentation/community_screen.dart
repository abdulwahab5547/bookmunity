import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/community_providers.dart';
import '../data/social_providers.dart';
import 'choose_username_screen.dart';
import 'community_widgets.dart';
import 'friends_screen.dart';

/// Community tab: reading updates, reviews, ratings, quotes and badges from
/// friends or from everyone, with reactions and comments. Friends and
/// friend requests live behind the people icon.
class CommunityScreen extends ConsumerWidget {
  const CommunityScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (ref.watch(communityRepositoryProvider) == null) {
      return Scaffold(
        appBar: const BrutalAppBar(title: 'Community'),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Sign in to join the community',
          message: ref.watch(firebaseReadyProvider)
              ? 'Updates, reviews and quotes need a Bookmunity account.'
              : 'The community is not available on this platform.',
        ),
      );
    }
    final profile = ref.watch(myProfileProvider);
    return profile.when(
      loading: () => const Scaffold(
        appBar: BrutalAppBar(title: 'Community'),
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: const BrutalAppBar(title: 'Community'),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'The community is unavailable',
          message: socialErrorMessage(error),
        ),
      ),
      data: (me) =>
          me == null ? const ChooseUsernameScreen() : const _CommunityHome(),
    );
  }
}

class _CommunityHome extends ConsumerWidget {
  const _CommunityHome();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final incoming =
        ref.watch(incomingRequestsProvider).valueOrNull ?? const [];
    final hasFriends = ref.watch(friendUidsProvider).isNotEmpty;
    void openPeople() => Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (_) => const FriendsScreen()));

    return DefaultTabController(
      length: 2,
      child: Scaffold(
        appBar: BrutalAppBar(
          title: 'Community',
          actions: [
            IconButton(
              tooltip: incoming.isEmpty
                  ? 'Friends and requests'
                  : 'Friends and requests (${incoming.length} new)',
              onPressed: openPeople,
              icon: Badge(
                isLabelVisible: incoming.isNotEmpty,
                label: Text('${incoming.length}'),
                child: const Icon(Icons.people_alt_outlined),
              ),
            ),
          ],
          bottom: const TabBar(
            tabs: [
              Tab(text: 'Friends'),
              Tab(text: 'Everyone'),
            ],
          ),
        ),
        body: TabBarView(
          children: [
            FeedList(
              query: FeedQuery.friends,
              empty: EmptyState(
                icon: Icons.group_outlined,
                title: hasFriends ? 'Nothing here yet' : 'Find your people',
                message: hasFriends
                    ? 'When you or your friends start or finish books, rate '
                          'them, share quotes or earn badges, it shows up here.'
                    : 'Add friends to see what they are reading. Meanwhile, '
                          'the Everyone tab shows the whole community.',
                action: BrutalPressable(
                  onPressed: openPeople,
                  backgroundColor: BrutalColors.blue,
                  foregroundColor: Colors.white,
                  child: const Text('Find friends'),
                ),
              ),
            ),
            const FeedList(
              query: FeedQuery.everyone,
              empty: EmptyState(
                icon: Icons.public,
                title: 'Quiet in here',
                message:
                    'Rate a book or share a quote from your highlights to '
                    'get things started.',
              ),
            ),
          ],
        ),
      ),
    );
  }
}
