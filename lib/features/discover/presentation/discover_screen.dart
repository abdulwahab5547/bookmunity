import 'package:flutter/material.dart';

import '../../../design/brutal_widgets.dart';

/// Browse and download free EPUBs from public libraries.
/// Placeholder: replaced by the Discover feature.
class DiscoverScreen extends StatelessWidget {
  const DiscoverScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return const Scaffold(
      appBar: BrutalAppBar(title: 'Discover'),
      body: EmptyState(
        icon: Icons.explore_outlined,
        title: 'Free books are coming here',
      ),
    );
  }
}
