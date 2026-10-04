import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/constants/us_states.dart';
import '../../../core/di/providers.dart';
import '../../../core/enums/app_enums.dart';
import '../../../core/router/app_router.dart';
import '../../../core/tokens/colors.dart';
import '../../../core/tokens/radii.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../data/models/organization.dart';
import '../../../state/auth_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/invite_code_card.dart';
import '../../widgets/primary_button.dart';

enum _Step { find, details, review, created }

/// Create an organization: find the practice in the public directory (or
/// enter it), check the details, review, create. Spec:
/// docs/superpowers/specs/2026-10-04-create-org-and-dm-without-org-design.md
/// and 2026-10-04-org-lookup-research.md.
class CreateOrgScreen extends ConsumerStatefulWidget {
  const CreateOrgScreen({super.key});

  @override
  ConsumerState<CreateOrgScreen> createState() => _CreateOrgScreenState();
}

class _CreateOrgScreenState extends ConsumerState<CreateOrgScreen> {
  _Step _step = _Step.find;

  // Find
  final _query = TextEditingController();
  Timer? _debounce;
  List<DirectoryEntry>? _suggested;
  List<DirectoryEntry>? _results;
  bool _searching = false;

  // Details
  DirectoryEntry? _from;
  final _name = TextEditingController();
  final _city = TextEditingController();
  final _nameKey = GlobalKey<AppTextFieldState>();
  PracticeType? _type;
  String? _state;

  bool _loading = false;
  String? _error;
  Organization? _created;

  @override
  void initState() {
    super.initState();
    ref
        .read(orgRepositoryProvider)
        .suggestedDirectory()
        .then(
          (s) => mounted ? setState(() => _suggested = s) : null,
          onError: (_) =>
              mounted ? setState(() => _suggested = const []) : null,
        );
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _query.dispose();
    _name.dispose();
    _city.dispose();
    super.dispose();
  }

  void _onQuery(String q) {
    _debounce?.cancel();
    if (q.trim().length < 2) {
      setState(() => _results = null);
      return;
    }
    _debounce = Timer(const Duration(milliseconds: 300), () async {
      setState(() => _searching = true);
      try {
        final r = await ref
            .read(orgRepositoryProvider)
            .searchDirectory(q.trim());
        // Drop answers to a query the user has already typed past.
        if (mounted && _query.text.trim() == q.trim()) {
          setState(() => _results = r);
        }
      } catch (_) {
        // Lookup is a convenience: "Enter it yourself" still works.
        if (mounted) setState(() => _results = const []);
      } finally {
        if (mounted) setState(() => _searching = false);
      }
    });
  }

  void _pick(DirectoryEntry? e) {
    FocusScope.of(context).unfocus();
    if (e != null && e.onDoqto) {
      _showAlreadyOnDoqto(e);
      return;
    }
    setState(() {
      _from = e;
      _name.text = e?.name ?? _query.text.trim();
      _city.text = e?.city ?? '';
      _state = usStates.contains(e?.state) ? e!.state : null;
      _type = e?.practiceType;
      _error = null;
      _step = _Step.details;
    });
  }

  Future<void> _showAlreadyOnDoqto(DirectoryEntry e) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(
            AppSpacing.xl,
            0,
            AppSpacing.xl,
            AppSpacing.xl,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                '${e.doqtoOrgName ?? e.name} is already on Doqto',
                style: AppText.heading,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                e.youAreListed
                    ? 'Your NPI is listed with this practice, so you can join now.'
                    : 'Ask a member for the invite code to join.',
                style: AppText.body,
              ),
              const SizedBox(height: AppSpacing.xl),
              if (e.youAreListed)
                AppButton(
                  label: 'Join ${e.doqtoOrgName ?? e.name}',
                  expand: true,
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    _joinExisting(e);
                  },
                )
              else
                AppButton(
                  label: 'Enter an invite code',
                  expand: true,
                  onPressed: () {
                    Navigator.of(sheet).pop();
                    context.push(AppRoutes.joinOrg);
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _joinExisting(DirectoryEntry e) async {
    try {
      await ref.read(orgProvider.notifier).joinByDirectory(e);
      await ref.read(authProvider.notifier).refreshOrgStatus();
      if (mounted) context.go(AppRoutes.myOrg);
    } catch (err) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(ErrorMessages.forApi(err))));
      }
    }
  }

  void _toReview() {
    final nameOk = _nameKey.currentState?.validate() ?? false;
    if (_type == null) {
      setState(() => _error = 'Choose a practice type.');
      return;
    }
    if (!nameOk) return;
    FocusScope.of(context).unfocus();
    setState(() {
      _error = null;
      _step = _Step.review;
    });
  }

  Future<void> _create() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final org = await ref
          .read(orgProvider.notifier)
          .createOrg(
            name: _name.text.trim(),
            city: _city.text.trim().isEmpty ? null : _city.text.trim(),
            state: _state,
            practiceType: _type,
            from: _from,
          );
      await ref.read(authProvider.notifier).refreshOrgStatus();
      if (!mounted) return;
      setState(() {
        _created = org;
        _step = _Step.created;
      });
    } catch (e) {
      if (mounted) setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _back() {
    setState(() {
      _error = null;
      _step = switch (_step) {
        _Step.review => _Step.details,
        _ => _Step.find,
      };
    });
  }

  // Your NPI under the picked Medicare group verifies the org on the spot.
  bool get _verifiesNow => _from?.youAreListed ?? false;

  @override
  Widget build(BuildContext context) {
    final canPop = _step == _Step.find || _step == _Step.created;
    return PopScope(
      canPop: canPop,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _back();
      },
      child: Scaffold(
        appBar: _step == _Step.created
            ? null
            : AppBar(
                title: const Text('Create organization'),
                leading: canPop
                    ? null
                    : IconButton(
                        tooltip: 'Back',
                        icon: const Icon(Icons.arrow_back_rounded),
                        onPressed: _back,
                      ),
              ),
        body: SafeArea(
          child: switch (_step) {
            _Step.find => _findStep(),
            _Step.details => _detailsStep(),
            _Step.review => _reviewStep(),
            _Step.created => _createdStep(),
          },
        ),
      ),
    );
  }

  Widget _findStep() {
    final q = _query.text.trim();
    final showing = q.length >= 2 ? _results : _suggested;
    return ListView(
      padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
      children: [
        Text('Find your practice', style: AppText.heading),
        const SizedBox(height: AppSpacing.xs),
        Text(
          'Search Medicare and NPI records so the details fill themselves in.',
          style: AppText.caption,
        ),
        const SizedBox(height: AppSpacing.lg),
        AppTextField(
          controller: _query,
          label: 'Practice or hospital name',
          hint: 'e.g. Riverside Cardiology',
          onChanged: _onQuery,
          suffix: _searching
              ? const Padding(
                  padding: EdgeInsets.all(14),
                  child: SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                )
              : null,
        ),
        const SizedBox(height: AppSpacing.lg),
        if (q.length < 2 && (_suggested?.isNotEmpty ?? false))
          Padding(
            padding: const EdgeInsets.only(bottom: AppSpacing.sm),
            child: Text('SUGGESTED FOR YOU', style: AppText.label),
          ),
        if (q.length >= 2 && showing != null && showing.isEmpty && !_searching)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: AppSpacing.md),
            child: Text(
              'No matches. Try a shorter name, or enter it yourself.',
              style: AppText.caption,
            ),
          ),
        for (final e in showing ?? const <DirectoryEntry>[])
          _EntryTile(entry: e, onTap: () => _pick(e)),
        const SizedBox(height: AppSpacing.md),
        TextButton(
          onPressed: () => _pick(null),
          child: const Text('Can\'t find it? Enter it yourself'),
        ),
      ],
    );
  }

  Widget _stepHeader(int n, String title) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Text(
        'STEP $n OF 2',
        style: AppText.label.copyWith(color: AppColors.medBlue),
      ),
      const SizedBox(height: AppSpacing.sm),
      Row(
        children: [
          for (var i = 1; i <= 2; i++) ...[
            Expanded(
              child: Container(
                height: 4,
                decoration: BoxDecoration(
                  color: i <= n ? AppColors.medBlue : AppColors.gray200,
                  borderRadius: BorderRadius.circular(AppRadii.full),
                ),
              ),
            ),
            if (i == 1) const SizedBox(width: 6),
          ],
        ],
      ),
      const SizedBox(height: AppSpacing.lg),
      Text(title, style: AppText.heading),
    ],
  );

  Widget _detailsStep() {
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
            children: [
              _stepHeader(1, 'About your organization'),
              if (_from != null) ...[
                const SizedBox(height: AppSpacing.xs),
                Text(
                  'Filled in from public records. Edit anything that\'s off.',
                  style: AppText.caption,
                ),
              ],
              const SizedBox(height: AppSpacing.lg),
              AppTextField(
                key: _nameKey,
                controller: _name,
                label: 'Organization name *',
                validator: Validators.orgName(),
              ),
              const SizedBox(height: AppSpacing.lg),
              Text('Practice type *', style: AppText.subheading),
              const SizedBox(height: AppSpacing.sm),
              for (final (t, label) in const [
                (PracticeType.independent, 'Independent practice'),
                (PracticeType.specialtyGroup, 'Specialty group'),
                (PracticeType.communityHospital, 'Community hospital'),
              ])
                _TypeOption(
                  label: label,
                  selected: _type == t,
                  onTap: () => setState(() {
                    _type = t;
                    _error = null;
                  }),
                ),
              const SizedBox(height: AppSpacing.md),
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    flex: 2,
                    child: AppTextField(controller: _city, label: 'City'),
                  ),
                  const SizedBox(width: AppSpacing.md),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text('State', style: AppText.subheading),
                        const SizedBox(height: AppSpacing.sm),
                        DropdownButtonFormField<String>(
                          initialValue: _state,
                          isExpanded: true,
                          items: [
                            for (final s in usStates)
                              DropdownMenuItem(value: s, child: Text(s)),
                          ],
                          onChanged: (s) => setState(() => _state = s),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              InlineError(_error),
            ],
          ),
        ),
        _Footer(
          note:
              'Doqto reviews new organizations. You can invite members and '
              'keep messaging while it\'s reviewed.',
          child: AppButton(
            label: 'Continue',
            expand: true,
            onPressed: _toReview,
          ),
        ),
      ],
    );
  }

  Widget _reviewStep() {
    final place = [
      _city.text.trim(),
      _state,
    ].whereType<String>().where((s) => s.isNotEmpty).join(', ');
    final typeLabel = switch (_type) {
      PracticeType.independent => 'Independent practice',
      PracticeType.specialtyGroup => 'Specialty group',
      PracticeType.communityHospital => 'Community hospital',
      null => '',
    };
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.all(AppSpacing.screenHorizontal),
            children: [
              _stepHeader(2, 'Check and create'),
              const SizedBox(height: AppSpacing.lg),
              Container(
                padding: const EdgeInsets.all(AppSpacing.lg),
                decoration: BoxDecoration(
                  color: AppColors.surface,
                  borderRadius: BorderRadius.circular(AppRadii.lg),
                  border: Border.all(color: AppColors.border),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    _Field('Name', _name.text.trim(), strong: true),
                    _Field('Practice type', typeLabel),
                    if (place.isNotEmpty) _Field('Location', place),
                  ],
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              const _Point(
                icon: Icons.shield_outlined,
                title: 'You\'ll be the admin',
                body:
                    'You can invite and remove members and manage who outside '
                    'the organization can reach them.',
              ),
              const SizedBox(height: AppSpacing.lg),
              _verifiesNow
                  ? const _Point(
                      icon: Icons.verified_outlined,
                      title: 'Verified right away',
                      body:
                          'Your NPI is listed with this practice in Medicare '
                          'records.',
                    )
                  : const _Point(
                      icon: Icons.schedule_rounded,
                      title: 'It starts as pending',
                      body:
                          'Doqto verifies new organizations and we\'ll let you '
                          'know when it\'s done. Colleagues can join right away; '
                          'groups open once it\'s verified.',
                      warm: true,
                    ),
              InlineError(_error),
            ],
          ),
        ),
        _Footer(
          child: AppButton(
            label: 'Create organization',
            expand: true,
            loading: _loading,
            onPressed: _create,
          ),
        ),
      ],
    );
  }

  Widget _createdStep() {
    final org = _created!;
    final verified = org.status == OrgStatus.active;
    return Column(
      children: [
        Expanded(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.xl,
              64,
              AppSpacing.xl,
              0,
            ),
            children: [
              Center(
                child: Container(
                  width: 88,
                  height: 88,
                  decoration: const BoxDecoration(
                    color: AppColors.medBlueLight,
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.check_rounded,
                    size: 44,
                    color: AppColors.medBlue,
                  ),
                ),
              ),
              const SizedBox(height: AppSpacing.xl),
              Text(
                'Organization created',
                style: AppText.display,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.sm),
              Text(
                verified
                    ? '${org.name} is verified. Invite your colleagues.'
                    : '${org.name} is waiting for verification. Invite colleagues '
                          'now; they can join while it\'s reviewed.',
                style: AppText.body,
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: AppSpacing.xl),
              InviteCodeCard(code: org.inviteCode),
            ],
          ),
        ),
        _Footer(
          child: AppButton(
            label: 'Done',
            expand: true,
            onPressed: () => context.go(AppRoutes.myOrg),
          ),
        ),
      ],
    );
  }
}

class _EntryTile extends StatelessWidget {
  const _EntryTile({required this.entry, required this.onTap});
  final DirectoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final members = entry.memberCount;
    final sub = [
      if (entry.place.isNotEmpty) entry.place,
      if (members != null && members > 1) '$members clinicians',
    ].join(' · ');
    return Padding(
      padding: const EdgeInsets.only(bottom: AppSpacing.sm),
      child: Material(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(AppRadii.md),
        child: InkWell(
          borderRadius: BorderRadius.circular(AppRadii.md),
          onTap: onTap,
          child: Container(
            constraints: const BoxConstraints(minHeight: 60),
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.md,
            ),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(AppRadii.md),
              border: Border.all(color: AppColors.border),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(entry.name, style: AppText.bodyPrimary),
                      if (sub.isNotEmpty) Text(sub, style: AppText.caption),
                    ],
                  ),
                ),
                if (entry.onDoqto)
                  const _Badge(
                    'On Doqto',
                    AppColors.medBlueLight,
                    AppColors.medBlueDark,
                  )
                else if (entry.youAreListed)
                  const _Badge(
                    'You\'re listed',
                    AppColors.greenLight,
                    AppColors.greenDark,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.text, this.bg, this.fg);
  final String text;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(AppRadii.full),
    ),
    child: Text(text, style: AppText.badge.copyWith(color: fg)),
  );
}

class _TypeOption extends StatelessWidget {
  const _TypeOption({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.sm),
    child: Material(
      color: selected ? AppColors.medBlueLight : AppColors.surface,
      borderRadius: BorderRadius.circular(AppRadii.md),
      child: InkWell(
        borderRadius: BorderRadius.circular(AppRadii.md),
        onTap: onTap,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(AppRadii.md),
            border: Border.all(
              color: selected ? AppColors.medBlue : AppColors.gray200,
              width: 1.5,
            ),
          ),
          child: Row(
            children: [
              Icon(
                selected
                    ? Icons.radio_button_checked_rounded
                    : Icons.radio_button_unchecked_rounded,
                color: selected ? AppColors.medBlue : AppColors.gray400,
                size: 20,
              ),
              const SizedBox(width: AppSpacing.md),
              Text(label, style: selected ? AppText.bodyPrimary : AppText.body),
            ],
          ),
        ),
      ),
    ),
  );
}

class _Field extends StatelessWidget {
  const _Field(this.label, this.value, {this.strong = false});
  final String label;
  final String value;
  final bool strong;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: AppSpacing.md),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(label, style: AppText.caption),
        Text(value, style: strong ? AppText.bodyPrimary : AppText.body),
      ],
    ),
  );
}

class _Point extends StatelessWidget {
  const _Point({
    required this.icon,
    required this.title,
    required this.body,
    this.warm = false,
  });
  final IconData icon;
  final String title;
  final String body;
  final bool warm;

  @override
  Widget build(BuildContext context) => Row(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: [
      Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(
          color: warm ? AppColors.amberLight : AppColors.medBlueLight,
          shape: BoxShape.circle,
        ),
        child: Icon(
          icon,
          size: 18,
          color: warm ? AppColors.amberText : AppColors.medBlue,
        ),
      ),
      const SizedBox(width: AppSpacing.md),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(title, style: AppText.bodyPrimary),
            const SizedBox(height: 2),
            Text(body, style: AppText.caption),
          ],
        ),
      ),
    ],
  );
}

class _Footer extends StatelessWidget {
  const _Footer({required this.child, this.note});
  final Widget child;
  final String? note;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(
      AppSpacing.screenHorizontal,
      AppSpacing.md,
      AppSpacing.screenHorizontal,
      AppSpacing.lg,
    ),
    child: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (note != null) ...[
          Text(note!, style: AppText.caption),
          const SizedBox(height: AppSpacing.md),
        ],
        child,
      ],
    ),
  );
}
