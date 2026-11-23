import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';

import '../../../design/brutal_theme.dart';
import '../../../design/brutal_widgets.dart';
import '../data/photo_processing.dart';
import '../data/social_models.dart';
import '../data/social_providers.dart';
import '../../../screens/settings_screen.dart';
import '../../stats/presentation/stats_screen.dart';
import 'choose_username_screen.dart';
import 'friend_profile_screen.dart';
import 'reader_profile.dart';
import 'user_avatar.dart';

/// The signed-in user's own profile (the You tab): the same Goodreads-style
/// page other readers see, plus edit, stats and settings in the app bar.
class MyProfileScreen extends ConsumerWidget {
  const MyProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final profile = ref.watch(myProfileProvider);
    return profile.when(
      loading: () => const Scaffold(
        appBar: BrutalAppBar(title: 'My profile'),
        body: Center(child: CircularProgressIndicator()),
      ),
      error: (error, _) => Scaffold(
        appBar: const BrutalAppBar(title: 'My profile'),
        body: EmptyState(
          icon: Icons.cloud_off_outlined,
          title: 'Profile unavailable',
          message: socialErrorMessage(error),
        ),
      ),
      data: (me) => me == null
          ? const ChooseUsernameScreen()
          : _MyProfileView(key: ValueKey(me.uid), me: me),
    );
  }
}

class _MyProfileView extends StatelessWidget {
  const _MyProfileView({required this.me, super.key});

  final Profile me;

  void _push(BuildContext context, Widget screen) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen));

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: BrutalAppBar(
        title: 'My profile',
        actions: [
          IconButton(
            tooltip: 'Edit profile',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => _push(context, const EditProfileScreen()),
          ),
          IconButton(
            tooltip: 'Statistics',
            icon: const Icon(Icons.insights_outlined),
            onPressed: () => _push(context, const StatsScreen()),
          ),
          IconButton(
            tooltip: 'Settings',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _push(context, const SettingsScreen()),
          ),
        ],
      ),
      body: ReaderProfileView(
        profile: me,
        avatar: InkWell(
          customBorder: const CircleBorder(),
          onTap: () => _push(context, const EditProfileScreen()),
          child: UserAvatar(uid: me.uid, hasPhoto: me.hasPhoto, size: 96),
        ),
      ),
    );
  }
}

/// Photo, display name and bio.
class EditProfileScreen extends ConsumerWidget {
  const EditProfileScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final me = ref.watch(myProfileProvider).valueOrNull;
    if (me == null) {
      return const Scaffold(
        appBar: BrutalAppBar(title: 'Edit profile'),
        body: Center(child: CircularProgressIndicator()),
      );
    }
    return _EditProfile(key: ValueKey(me.uid), me: me);
  }
}

class _EditProfile extends ConsumerStatefulWidget {
  const _EditProfile({required this.me, super.key});

  final Profile me;

  @override
  ConsumerState<_EditProfile> createState() => _EditProfileState();
}

class _EditProfileState extends ConsumerState<_EditProfile> {
  final _form = GlobalKey<FormState>();
  late final _name = TextEditingController(text: widget.me.displayName);
  late final _bio = TextEditingController(text: widget.me.bio);
  bool _savingDetails = false;
  bool _savingPhoto = false;

  @override
  void dispose() {
    _name.dispose();
    _bio.dispose();
    super.dispose();
  }

  bool get _dirty =>
      _name.text.trim() != widget.me.displayName ||
      _bio.text.trim() != widget.me.bio;

  void _message(String text) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _saveDetails() async {
    if (!_form.currentState!.validate()) return;
    setState(() => _savingDetails = true);
    try {
      await ref
          .read(socialRepositoryProvider)!
          .updateProfile(displayName: _name.text, bio: _bio.text);
      if (mounted) _message('Profile saved.');
    } catch (error) {
      if (mounted) _message(socialErrorMessage(error));
    } finally {
      if (mounted) setState(() => _savingDetails = false);
    }
  }

  bool get _canUseCamera =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  Future<void> _changePhoto() async {
    final choice = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('Choose a photo'),
              onTap: () => Navigator.pop(context, 'gallery'),
            ),
            if (_canUseCamera)
              ListTile(
                leading: const Icon(Icons.photo_camera_outlined),
                title: const Text('Take a photo'),
                onTap: () => Navigator.pop(context, 'camera'),
              ),
            if (widget.me.hasPhoto)
              ListTile(
                leading: const Icon(Icons.pets_outlined),
                title: const Text('Use my cute avatar instead'),
                onTap: () => Navigator.pop(context, 'remove'),
              ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    final repository = ref.read(socialRepositoryProvider)!;
    setState(() => _savingPhoto = true);
    try {
      if (choice == 'remove') {
        await repository.removePhoto();
        return;
      }
      final picked = await ImagePicker().pickImage(
        source: choice == 'camera' ? ImageSource.camera : ImageSource.gallery,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 90,
        preferredCameraDevice: CameraDevice.front,
      );
      if (picked == null) return;
      final jpeg = await prepareProfilePhoto(await picked.readAsBytes());
      if (jpeg == null) {
        if (mounted) _message('That file is not a supported image.');
        return;
      }
      await repository.setPhoto(jpeg);
    } catch (error) {
      if (mounted) _message(socialErrorMessage(error));
    } finally {
      if (mounted) setState(() => _savingPhoto = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final me = widget.me;
    final avatar = Stack(
      clipBehavior: Clip.none,
      children: [
        UserAvatar(uid: me.uid, hasPhoto: me.hasPhoto, size: 112),
        if (_savingPhoto)
          const Positioned.fill(
            child: Center(child: CircularProgressIndicator()),
          ),
        Positioned(
          right: -4,
          bottom: -4,
          child: IconButton.filled(
            tooltip: 'Change photo',
            onPressed: _savingPhoto ? null : _changePhoto,
            style: IconButton.styleFrom(
              backgroundColor: BrutalColors.blue,
              side: BorderSide(color: theme.colorScheme.surface, width: 2),
            ),
            icon: const Icon(Icons.photo_camera, color: Colors.white, size: 18),
          ),
        ),
      ],
    );

    return Scaffold(
      appBar: const BrutalAppBar(title: 'Edit profile'),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ProfileHeader(profile: me, avatar: avatar),
          const SizedBox(height: 24),
          Form(
            key: _form,
            onChanged: () => setState(() {}),
            child: Column(
              children: [
                TextFormField(
                  controller: _name,
                  maxLength: 50,
                  textCapitalization: TextCapitalization.words,
                  decoration: const InputDecoration(labelText: 'Display name'),
                  validator: (value) => (value?.trim().isEmpty ?? true)
                      ? 'Enter the name friends will see.'
                      : null,
                ),
                const SizedBox(height: 8),
                TextFormField(
                  controller: _bio,
                  maxLength: Profile.maxBioLength,
                  maxLines: 3,
                  minLines: 2,
                  textCapitalization: TextCapitalization.sentences,
                  decoration: const InputDecoration(
                    labelText: 'Bio',
                    hintText: 'What do you love to read?',
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),
          BrutalPressable(
            onPressed: _savingDetails || !_dirty ? null : _saveDetails,
            backgroundColor: BrutalColors.green,
            child: Center(child: Text(_savingDetails ? 'Saving…' : 'Save')),
          ),
          const SizedBox(height: 12),
          Text(
            'Your username @${me.username} can’t be changed.',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
    );
  }
}
