import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../../../core/router/app_router.dart';
import '../../../core/tokens/spacing.dart';
import '../../../core/tokens/typography.dart';
import '../../../core/utils/error_messages.dart';
import '../../../core/utils/validators.dart';
import '../../../state/auth_state.dart';
import '../../../state/org_state.dart';
import '../../widgets/app_text_field.dart';
import '../../widgets/fade_slide_in.dart';
import '../../widgets/inline_error.dart';
import '../../widgets/primary_button.dart';

class JoinOrgScreen extends ConsumerStatefulWidget {
  const JoinOrgScreen({super.key});

  @override
  ConsumerState<JoinOrgScreen> createState() => _JoinOrgScreenState();
}

class _JoinOrgScreenState extends ConsumerState<JoinOrgScreen> {
  final _code = TextEditingController();
  final _codeKey = GlobalKey<AppTextFieldState>();
  bool _loading = false;
  String? _error;

  Future<void> _submit() async {
    if (!(_codeKey.currentState?.validate() ?? false)) return;
    // The server compares the canonical `XXXX·1234` exactly.
    final code = Validators.normalizeInviteCode(_code.text);
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      await ref.read(orgProvider.notifier).joinOrg(code);
      // Re-evaluate the auth stage against the real org status returned by the
      // server. `refreshOrgStatus()` flips AuthStage to signedIn / pending /
      // suspended; the router redirect picks up the change and navigates us
      // to /chats or /org/pending automatically. Do NOT hardcode a route here
      // — that caused the "joined successfully but stuck on get-started" bug.
      await ref.read(authProvider.notifier).refreshOrgStatus();
      if (!mounted) return;
      final stage = ref.read(authProvider).stage;
      context.go(switch (stage) {
        AuthStage.signedIn => AppRoutes.chats,
        AuthStage.pendingVerification => AppRoutes.pending,
        _ => AppRoutes.orgSelection,
      });
    } catch (e) {
      setState(() => _error = ErrorMessages.forApi(e));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Join Organization')),
      // Scrolls when the keyboard (or a large text size) leaves too little
      // room; looks the same otherwise.
      body: SingleChildScrollView(
        // Explicit padding drops the automatic safe-area inset; add it back so
        // the last control clears the home indicator.
        padding: const EdgeInsets.all(AppSpacing.screenHorizontal).copyWith(
          bottom: AppSpacing.screenHorizontal + MediaQuery.paddingOf(context).bottom,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: AppSpacing.lg),
            FadeSlideIn.staggered(
              0,
              AppTextField(
                key: _codeKey,
                controller: _code,
                label: 'Invite code',
                hint: 'APOL·4827',
                style: AppText.inviteCode,
                // Codes are upper-case letters and digits (APOL·4827).
                textCapitalization: TextCapitalization.characters,
                autocorrect: false,
                // The middle dot is not on a phone keyboard: the formatter
                // inserts it, so APOL4827 / apol.4827 / APOL-4827 all work.
                inputFormatters: const [InviteCodeFormatter()],
                textInputAction: TextInputAction.done,
                onSubmitted: (_) => _submit(),
                validator: Validators.inviteCode(),
                // Exactly nine characters: a complete code puts the keyboard
                // away by itself.
                dismissOnValid: true,
                onChanged: (_) {
                  if (_error != null) setState(() => _error = null);
                },
              ),
            ),
            InlineError(_error),
            const SizedBox(height: AppSpacing.xl),
            FadeSlideIn.staggered(
              1,
              AppButton(
                label: 'Join',
                onPressed: _submit,
                loading: _loading,
                expand: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
