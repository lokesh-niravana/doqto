import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:image_picker/image_picker.dart';

import '../../../core/constants/strings.dart';
import '../../../core/di/providers.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
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
    super.dispose();
  }

  Future<void> _save() async {
    if (_saving) return;
    FocusScope.of(context).unfocus();
    setState(() => _saving = true);
    try {
      final years = _years.text.trim().isEmpty ? null : int.tryParse(_years.text.trim());
      final patch = UserPatchBody(
        fullName: _fullName.text.trim(),
        email: _email.text.trim().isEmpty ? null : _email.text.trim(),
        specialty: _specialty.text.trim(),
        bio: _bio.text.trim(),
        city: _city.text.trim(),
        state: _state.text.trim(),
        yearsOfExperience: years,
        skills: _skills,
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
      builder: (ctx) => SafeArea(
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
                onTap: () {
                  Navigator.pop(ctx);
                  _removeAvatar();
                },
              ),
            const SizedBox(height: AppSpacing.sm),
          ],
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
        body: ListView(
          physics: const NeverScrollableScrollPhysics(),
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.screenHorizontal,
            vertical: AppSpacing.lg,
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
      );
    }
    return Scaffold(
      backgroundColor: AppColors.appBg,
      appBar: AppBar(
        title: const Text('Edit profile'),
      ),
      body: SafeArea(
        child: ListView(
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
                  DoctorAvatar(
                    initials: user.initials,
                    size: AvatarSize.xxl,
                    imageUrl: userAvatarUrl(user.id, user.avatarUrl),
                  ),
                  Positioned(
                    right: 0,
                    bottom: 0,
                    child: Material(
                      color: AppColors.medBlue,
                      shape: const CircleBorder(),
                      child: InkWell(
                        customBorder: const CircleBorder(),
                        onTap: _uploadingAvatar ? null : _openPhotoSheet,
                        child: Container(
                          width: 36,
                          height: 36,
                          alignment: Alignment.center,
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
                      controller: _fullName,
                      label: 'Full name',
                      hint: 'Dr. Priya Shah',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _email,
                      label: 'Email',
                      hint: 'you@clinic.com',
                      keyboardType: TextInputType.emailAddress,
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _specialty,
                      label: 'Specialty',
                      hint: 'Cardiology',
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _years,
                      label: 'Years of experience',
                      hint: 'e.g. 12',
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
                    ),
                    const SizedBox(height: AppSpacing.md),
                    AppTextField(
                      controller: _state,
                      label: 'State / Region',
                      hint: 'Karnataka',
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
                      initial: _skills,
                      onChanged: (s) => _skills = s,
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
      child: Text(title.toUpperCase(), style: AppText.label),
    );
  }
}
