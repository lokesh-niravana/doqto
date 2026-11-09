import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/models/network_profile.dart';
import 'doctor_avatar.dart';
import 'primary_button.dart';
import 'section_card.dart';
import '../../core/utils/avatar_urls.dart';

/// A received connection invitation: avatar + name + headline, an optional
/// mutuals line, and a paired Accept / Ignore action row. Composed on
/// [SectionCard]; the parent owns the (optimistic) accept/ignore callbacks.
class InvitationCard extends StatelessWidget {
  final Invitation invitation;
  final VoidCallback onAccept;
  final VoidCallback onIgnore;

  /// Tapping the card body (e.g. → the sender's profile).
  final VoidCallback? onTap;

  const InvitationCard({
    super.key,
    required this.invitation,
    required this.onAccept,
    required this.onIgnore,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final party = invitation.sender;
    final name = party?.fullName ?? '';
    return SectionCard(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              DoctorAvatar(
                initials: party?.initials ?? '?',
                colorIndex: party?.avatarIndex ?? 0,
                imageUrl: userAvatarUrl(party?.id, party?.avatarUrl),
                size: AvatarSize.lg,
                heroTag: party != null ? 'member-avatar-${party.id}' : null,
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      name,
                      style: AppText.subheading,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    if (_notEmpty(party?.headline)) ...[
                      const SizedBox(height: 2),
                      Text(
                        party!.headline!,
                        style: AppText.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ] else if (_notEmpty(party?.specialty)) ...[
                      const SizedBox(height: 2),
                      Text(
                        party!.specialty!,
                        style: AppText.caption,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
          if (_notEmpty(invitation.message)) ...[
            const SizedBox(height: AppSpacing.sm),
            Text(
              invitation.message!,
              style: AppText.bodyPrimary,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: AppSpacing.md),
          Row(
            children: [
              Expanded(
                child: AppButton(
                  label: Strings.netAccept,
                  onPressed: onAccept,
                  expand: true,
                ),
              ),
              const SizedBox(width: AppSpacing.sm),
              Expanded(
                child: AppButton(
                  label: Strings.netIgnore,
                  variant: AppButtonVariant.ghost,
                  onPressed: onIgnore,
                  expand: true,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  static bool _notEmpty(String? s) => s != null && s.trim().isNotEmpty;
}
