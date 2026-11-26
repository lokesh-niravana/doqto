import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/tokens/motion.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../data/repositories/user_repository.dart';
import '../../../state/auth_state.dart';
import '../../widgets/app_skeleton.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/doctor_avatar.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/primary_button.dart';
import '../../widgets/skills_input.dart';
import '../media/image_crop_screen.dart';
import '../../../core/utils/avatar_urls.dart';

const _changePhotoLabel = 'Change photo';
const _photoAccessOff =
    'Photo access is turned off for Doqto. Turn it on in Settings.';
const _cameraAccessOff =
    'Camera access is turned off for Doqto. Turn it on in Settings.';
const _openSettings = 'Open Settings';
const _removePhotoTitle = 'Remove photo?';
const _removePhotoBody = 'Colleagues will see your initials instead.';
const _removeAction = 'Remove';

class ProfileEditScreen extends ConsumerStatefulWidget {
  const ProfileEditScreen({super.key});

  @override
  ConsumerState<ProfileEditScreen> createState() => _ProfileEditScreenState();
}

class _ProfileEditScreenState extends ConsumerState<ProfileEditScreen> {
  late final TextEditingController _fullName;
  late final TextEditingController _email;
  late final TextEditingController _specialty;
  late final TextEditingController _bio;
  late final TextEditingController _city;
  late final TextEditingController _state;
  late final TextEditingController _years;
  late List<String> _skills;

  bool _saving = false;
  bool _uploadingAvatar = false;

  final _scroll = ScrollController();
  final _emailKey = GlobalKey<AppTextFieldState>();
  final _nameKey = GlobalKey<AppTextFieldState>();
  final _skillsKey = GlobalKey<SkillsInputState>();

  /// Typed into the skills field but not added yet.
  String _skillDraft = '';

  /// The values the form opened with, to tell an edit from a look.
  late final List<String> _initialText;
  late final List<String> _initialSkills;
  bool _dirty = false;

  List<TextEditingController> get _controllers =>
      [_fullName, _email, _specialty, _bio, _city, _state, _years];

  bool _computeDirty() {
    for (var i = 0; i < _controllers.length; i++) {
      if (_controllers[i].text.trim() != _initialText[i]) return true;
    }
    if (_skillDraft.isNotEmpty) return true;
    if (_skills.length != _initialSkills.length) return true;
    for (var i = 0; i < _skills.length; i++) {
      if (_skills[i] != _initialSkills[i]) return true;
    }
    return false;
  }

  // PopScope reads `_dirty` at build time: rebuild only when it flips.
  void _onEdited() {
    final dirty = _computeDirty();
    if (dirty != _dirty && mounted) setState(() => _dirty = dirty);
  }

  /// The name is the one thing everyone else sees: never blank.
  static String? _nameError(String v) =>
      v.trim().isEmpty ? Strings.profileNameRequired : null;

  /// The account has no phone number, so the server will not let its email
  /// go (one of the two must stay): an emptied field is stopped here.
  bool _emailRequired = false;

  /// Empty is fine (the address is optional) unless it is the account's only
  /// identifier; anything typed must be an address.
  String? _emailError(String v) {
    if (v.trim().isEmpty) {
      return _emailRequired ? Strings.profileEmailCannotClear : null;
    }
    return Validators.email()(v);
  }

  Future<void> _confirmDiscard() async {
    final discard = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(Strings.profileDiscardTitle),
        content: const Text(Strings.profileDiscardBody),
        actions: [
          TextButton(
            key: const ValueKey('profile-discard-keep'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.keepEditing),
          ),
          TextButton(
            key: const ValueKey('profile-discard-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text(Strings.discard),
          ),
        ],
      ),
    );
    if (discard == true && mounted) Navigator.of(context).pop();
  }

  @override
  void initState() {
    super.initState();
    final u = ref.read(authProvider).user!;
    _fullName = TextEditingController(text: u.fullName);
    _email = TextEditingController(text: u.email ?? '');
    _specialty = TextEditingController(text: u.specialty ?? '');
    _bio = TextEditingController(text: u.bio ?? '');
    _city = TextEditingController(text: u.city ?? '');
    _state = TextEditingController(text: u.state ?? '');
    _years = TextEditingController(
      text: u.yearsOfExperience == null ? '' : '${u.yearsOfExperience}',
    );
    _skills = [...u.skills];
    _emailRequired = (u.email ?? '').trim().isNotEmpty && u.phone.trim().isEmpty;
    _initialText = [for (final c in _controllers) c.text.trim()];
    _initialSkills = [...u.skills];
    for (final c in _controllers) {
      c.addListener(_onEdited);
    }
  }

  @override
  void dispose() {
    _fullName.dispose();
    _email.dispose();
    _specialty.dispose();
    _bio.dispose();
    _city.dispose();
    _state.dispose();
    _years.dispose();
    _scroll.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    // A blank name or a bad address is stopped here and shown on its own
    // field, instead of going to the server.
    final nameBad = _nameError(_fullName.text) != null;
    final emailBad = _emailError(_email.text) != null;
    if (nameBad || emailBad) {
      // Both fields are near the top of a long list; from the Save button
      // they may be scrolled out and unbuilt.
      if ((_nameKey.currentState == null || _emailKey.currentState == null) &&
          _scroll.hasClients) {
        await _scroll.animateTo(
          0,
          duration: AppMotion.maybe(context, AppMotion.enter),
          curve: AppMotion.standard,
        );
        if (!mounted) return;
      }
      // Both are marked; the first invalid one is scrolled to.
      if (nameBad) _nameKey.currentState?.validate();
      if (emailBad) _emailKey.currentState?.validate();
      final fieldContext =
          (nameBad ? _nameKey : _emailKey).currentContext;
      if (fieldContext != null && fieldContext.mounted) {
        await Scrollable.ensureVisible(
          fieldContext,
          alignment: 0.1,
          duration: AppMotion.maybe(context, AppMotion.enter),
          curve: AppMotion.standard,
        );
      }
      return;
    }
    // A skill typed but not added with + is added, not dropped.
    _skillsKey.currentState?.commitDraft();
    final draft = _skillDraft;
    if (draft.isNotEmpty &&
        _skills.length < 20 &&
        !_skills.any((s) => s.toLowerCase() == draft.toLowerCase())) {
      _skills = [..._skills, draft];
    }
    setState(() => _saving = true);
    try {
      final years = _years.text.trim().isEmpty ? null : int.tryParse(_years.text.trim());
      // A value that was there and has been emptied is sent as an explicit
      // null. Left out, the server keeps the old one and the save would be
      // reported as done without having happened.
      final hadEmail = _initialText[_controllers.indexOf(_email)].isNotEmpty;
      final hadYears = _initialText[_controllers.indexOf(_years)].isNotEmpty;
      final patch = UserPatchBody(
        fullName: _fullName.text.trim(),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        specialty: _specialty.text.trim(),
        bio: _bio.text.trim(),
        city: _city.text.trim(),
        state: _state.text.trim(),
        yearsOfExperience: years,
        skills: _skills,
        clear: {
          if (hadEmail && _email.text.trim().isEmpty) UserPatchBody.clearEmail,
          if (hadYears && _years.text.trim().isEmpty)
            UserPatchBody.clearYearsOfExperience,
        },
      );
      final updated = await ref.read(userRepositoryProvider).updateMe(patch);
      ref.read(authProvider.notifier).setUser(updated);
      if (!mounted) return;
      context.pop();
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _pickImage(ImageSource source) async {
    if (_uploadingAvatar) return;
    try {
      final picker = ImagePicker();
      final xfile = await picker.pickImage(
        source: source,
        maxWidth: 1024,
        maxHeight: 1024,
        imageQuality: 85,
      );
      if (xfile == null || !mounted) return;
      // Crop before upload: circle mask, square output. Null = cancelled.
      final file = await showImageCrop(
        context,
        File(xfile.path),
        circle: true,
        title: Strings.cropTitle,
      );
      if (file == null || !mounted) return;
      setState(() => _uploadingAvatar = true);
      final updated = await ref.read(userRepositoryProvider).uploadAvatar(file);
      ref.read(authProvider.notifier).setUser(updated);
    } on PlatformException catch (e) {
      if (!mounted) return;
      // image_picker's codes for access the user has turned off in Settings:
      // say so, and offer the way there, instead of a generic failure.
      final denied = switch (e.code) {
        'camera_access_denied' => _cameraAccessOff,
        'photo_access_denied' => _photoAccessOff,
        _ => null,
      };
      ScaffoldMessenger.of(context).showSnackBar(
        denied != null
            ? SnackBar(
                content: Text(denied),
                action: SnackBarAction(
                  label: _openSettings,
                  onPressed: openAppSettings,
                ),
              )
            : SnackBar(
                content: Text(ErrorMessages.forApi(e)),
                backgroundColor: AppColors.red,
              ),
      );
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  /// Removing the photo is immediate and visible to every colleague, so it
  /// is confirmed like the app's other destructive actions.
  Future<bool> _confirmRemovePhoto() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text(_removePhotoTitle),
        content: const Text(_removePhotoBody),
        actions: [
          TextButton(
            key: const ValueKey('remove-photo-cancel'),
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text(Strings.cancel),
          ),
          TextButton(
            key: const ValueKey('remove-photo-confirm'),
            onPressed: () => Navigator.of(ctx).pop(true),
            style: TextButton.styleFrom(foregroundColor: AppColors.red),
            child: const Text(_removeAction),
          ),
        ],
      ),
    );
    return ok == true;
  }

  Future<void> _removeAvatar() async {
    if (_uploadingAvatar) return;
    setState(() => _uploadingAvatar = true);
    try {
      final updated = await ref.read(userRepositoryProvider).deleteAvatar();
      ref.read(authProvider.notifier).setUser(updated);
    } catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(ErrorMessages.forApi(e)),
        backgroundColor: AppColors.red,
      ));
    } finally {
      if (mounted) setState(() => _uploadingAvatar = false);
    }
  }

  void _openPhotoSheet() {
    final hasAvatar = ref.read(authProvider).user?.avatarUrl != null;
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: AppColors.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(AppRadii.lg)),
      ),
      // Sized to its content and scrollable, so nothing clips at large
      // text or on a short screen.
      isScrollControlled: true,
      useSafeArea: true,
      builder: (ctx) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(
            maxHeight: MediaQuery.sizeOf(ctx).height * 0.9,
          ),
          child: SingleChildScrollView(
            child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: Icon(Icons.photo_library_outlined, color: AppColors.medBlue),
              title: const Text('Choose from library'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.gallery);
              },
            ),
            ListTile(
              leading: Icon(Icons.photo_camera_outlined, color: AppColors.medBlue),
              title: const Text('Take a photo'),
              onTap: () {
                Navigator.pop(ctx);
                _pickImage(ImageSource.camera);
              },
            ),
            if (hasAvatar)
              ListTile(
                leading: Icon(Icons.delete_outline, color: AppColors.red),
                title: Text('Remove photo', style: TextStyle(color: AppColors.red)),
                onTap: () async {
                  Navigator.pop(ctx);
                  if (await _confirmRemovePhoto() && mounted) _removeAvatar();
                },
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
        ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final user = ref.watch(authProvider).user;
    if (user == null) {
      return Scaffold(
        backgroundColor: AppColors.appBg,
        appBar: AppBar(title: const Text('Edit profile')),
        // The grey blocks are only drawn; a screen reader hears "Loading" once.
        body: Semantics(
          container: true,
          label: Strings.loading,
          liveRegion: true,
          child: ExcludeSemantics(
            child: ListView(
              physics: const NeverScrollableScrollPhysics(),
              padding: EdgeInsets.fromLTRB(
                AppSpacing.screenHorizontal,
                AppSpacing.lg,
                AppSpacing.screenHorizontal,
                AppSpacing.lg + MediaQuery.paddingOf(context).bottom,
              ),
              children: [
                Center(child: AppSkeleton.circle(size: 104)),
                const SizedBox(height: AppSpacing.xl),
                for (var i = 0; i < 4; i++) ...[
                  AppSkeleton.line(width: 80),
                  const SizedBox(height: AppSpacing.sm),
                  AppSkeleton.block(height: 48),
                  const SizedBox(height: AppSpacing.md),
                ],
              ],
            ),
          ),
        ),
      );
    }
    return PopScope(
      // Leaving with edits asks first; a clean form (and the swipe back)
      // leaves at once.
      canPop: !_dirty,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _confirmDiscard();
      },
      child: Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: const Text('Edit profile'),
      ),
      body: SafeArea(
        child: ListView(
          controller: _scroll,
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.screenHorizontal,
            AppSpacing.lg,
            AppSpacing.screenHorizontal,
            AppSpacing.xxl,
          ),
          children: [
            FadeSlideIn.staggered(
                0,
                Center(
                  child: Stack(
                    children: [
                  // 4pt of room round the avatar so the camera button's 44pt
                  // target fits inside the stack; the 36pt disc sits where it
                  // always did, on the avatar's bottom-right edge.
                  Padding(
                    padding: const EdgeInsets.all(4),
                    child: DoctorAvatar(
                      initials: user.initials,
                      size: AvatarSize.xxl,
                      imageUrl: userAvatarUrl(user.id, user.avatarUrl),
                    ),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Semantics(
                      button: true,
                      enabled: !_uploadingAvatar,
                      label: _changePhotoLabel,
                      child: Material(
                        type: MaterialType.transparency,
                        child: InkWell(
                          key: const ValueKey('profile-edit-photo'),
                          customBorder: const CircleBorder(),
                          onTap: _uploadingAvatar ? null : _openPhotoSheet,
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            child: Center(
                              child: Container(
                                width: 36,
                                height: 36,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: AppColors.medBlue,
                                  shape: BoxShape.circle,
                                ),
                                child: _uploadingAvatar
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                          valueColor: AlwaysStoppedAnimation(AppColors.white),
                                        ),
                                      )
                                    : Icon(Icons.camera_alt_outlined,
                                        color: AppColors.white, size: 18),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                    ],
                  ),
                )),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
                1,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Status under the name (batch 6).
                    ListTile(
                      key: const ValueKey('profile-edit-status'),
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(Icons.mood_outlined, color: AppColors.medBlue),
                      title: Text('Status', style: AppText.bodyPrimary),
                      subtitle: Text(user.statusLabel() ?? 'Not set', style: AppText.caption),
                      trailing: Icon(Icons.chevron_right, color: AppColors.textMuted),
                      onTap: () => context.push(AppRoutes.profileStatus),
                    ),
                    const SizedBox(height: AppSpacing.md),
                    _SectionTitle('Basic'),
                    AppTextField(
                      key: _nameKey,
                      controller: _fullName,
                      validator: _nameError,
                      label: 'Full name',
                      hint: 'Dr. Priya Shah',
                      autofillHints: const [AutofillHints.name],
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      key: _emailKey,
                      controller: _email,
                      label: 'Email',
                      validator: _emailError,
                      hint: 'you@clinic.com',
                      keyboardType: TextInputType.emailAddress,
                      autofillHints: const [AutofillHints.email],
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _specialty,
                      label: 'Specialty',
                      hint: 'Cardiology',
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _years,
                      label: 'Years of experience',
                      hint: 'e.g. 12',
                      textInputAction: TextInputAction.next,
                      keyboardType: TextInputType.number,
                      inputFormatters: [
                        FilteringTextInputFormatter.digitsOnly,
                        LengthLimitingTextInputFormatter(2),
                      ],
                    ),
                  ],
                )),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
                2,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SectionTitle('Location'),
                    AppTextField(
                      controller: _city,
                      label: 'City',
                      hint: 'Bengaluru',
                      textInputAction: TextInputAction.next,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _state,
                      label: 'State / Region',
                      hint: 'Karnataka',
                      textInputAction: TextInputAction.next,
                    ),
                  ],
                )),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
                3,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SectionTitle('About'),
                    AppTextField(
                      controller: _bio,
                      label: 'Bio',
                      textCapitalization: TextCapitalization.sentences,
                      hint: 'Short description of your practice.',
                      maxLength: 500,
                      // 500 characters need room to be read back: several
                      // lines with a return key. Tap outside still dismisses
                      // the keyboard (AppTextField).
                      maxLines: 5,
                      keyboardType: TextInputType.multiline,
                      textInputAction: TextInputAction.newline,
                    ),
                    // How much of the 500 is used. Drawn only: the field
                    // itself reports its length and limit to screen readers.
                    ExcludeSemantics(
                      child: Padding(
                        padding: const EdgeInsets.only(top: AppSpacing.xs),
                        child: ValueListenableBuilder<TextEditingValue>(
                          valueListenable: _bio,
                          builder: (context, value, _) => Text(
                            '${value.text.characters.length}/500',
                            key: const ValueKey('profile-edit-bio-counter'),
                            textAlign: TextAlign.end,
                            style: AppText.caption,
                          ),
                        ),
                      ),
                    ),
                  ],
                )),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
                4,
                Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _SectionTitle('Skills'),
                    SkillsInput(
                      key: _skillsKey,
                      initial: _skills,
                      onChanged: (s) {
                        _skills = [...s];
                        _onEdited();
                      },
                      onDraftChanged: (d) {
                        _skillDraft = d;
                        _onEdited();
                      },
                    ),
                  ],
                )),
            const SizedBox(height: AppSpacing.xxl),
            FadeSlideIn.staggered(
                5,
                AppButton(
                  label: 'Save changes',
                  onPressed: _save,
                  loading: _saving,
                  expand: true,
                )),
          ],
        ),
      ),
      ),
    );
  }
}

class _SectionTitle extends StatelessWidget {
  final String title;
  const _SectionTitle(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm, left: AppSpacing.xs),
      child: Semantics(header: true, child: Text(title.toUpperCase(), style: AppText.label)),
    );
  }
}
