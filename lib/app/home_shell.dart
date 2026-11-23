import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../features/discover/presentation/discover_screen.dart';
import '../features/library/presentation/library_screen.dart';
import '../features/social/data/social_providers.dart';
import '../features/social/presentation/community_screen.dart';
import '../features/social/presentation/my_profile_screen.dart';

/// Selected bottom tab. Exposed so other screens can switch tabs, e.g. the
/// empty library pointing at Discover.
final homeTabProvider = StateProvider<HomeTab>((ref) => HomeTab.library);

enum HomeTab { library, discover, community, you }

/// The signed-in app: Library, Discover, Community and You.
class HomeShell extends ConsumerWidget {
  const HomeShell({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tab = ref.watch(homeTabProvider);
    final social = ref.watch(socialRepositoryProvider) != null;
    // Without Firebase (tests, unsupported platforms) only the offline tabs
    // are offered.
    final tabs = [
      HomeTab.library,
      HomeTab.discover,
      if (social) ...[HomeTab.community, HomeTab.you],
    ];
    final index = tabs.indexOf(tab).clamp(0, tabs.length - 1);
    return Scaffold(
      body: IndexedStack(
        index: index,
        children: [for (final tab in tabs) _screenFor(tab)],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: index,
        onDestinationSelected: (value) =>
            ref.read(homeTabProvider.notifier).state = tabs[value],
        destinations: [for (final tab in tabs) _destinationFor(tab)],
      ),
    );
  }

  Widget _screenFor(HomeTab tab) => switch (tab) {
    HomeTab.library => const LibraryScreen(),
    HomeTab.discover => const DiscoverScreen(),
    HomeTab.community => const CommunityScreen(),
    HomeTab.you => const MyProfileScreen(),
  };

  NavigationDestination _destinationFor(HomeTab tab) => switch (tab) {
    HomeTab.library => const NavigationDestination(
      icon: Icon(Icons.local_library_outlined),
      selectedIcon: Icon(Icons.local_library),
      label: 'Library',
    ),
    HomeTab.discover => const NavigationDestination(
      icon: Icon(Icons.explore_outlined),
      selectedIcon: Icon(Icons.explore),
      label: 'Discover',
    ),
    HomeTab.community => const NavigationDestination(
      icon: Icon(Icons.forum_outlined),
      selectedIcon: Icon(Icons.forum),
      label: 'Community',
    ),
    HomeTab.you => const NavigationDestination(
      icon: Icon(Icons.person_outline),
      selectedIcon: Icon(Icons.person),
      label: 'You',
    ),
  };
}
