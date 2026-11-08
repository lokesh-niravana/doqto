import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/enums/app_enums.dart';
import '../../core/tokens/colors.dart';
import '../../core/tokens/motion.dart';

enum AvatarSize { sm, md, lg, xl, xxl }

class DoctorAvatar extends StatelessWidget {
  final String initials;
  final int colorIndex;
  final AvatarSize size;
  final PresenceStatusDot? presence;
  final String? imageUrl;
  final bool isSelected;

  /// When provided, the avatar is wrapped in a [Hero] for shared-element
  /// transitions (e.g. chat list → chat header → profile).
  final Object? heroTag;

  const DoctorAvatar({
    super.key,
    required this.initials,
    this.colorIndex = 0,
    this.size = AvatarSize.lg,
    this.presence,
    this.imageUrl,
    this.isSelected = false,
    this.heroTag,
  });

  @override
  Widget build(BuildContext context) {
    final dim = switch (size) {
      AvatarSize.xxl => 104.0,
      AvatarSize.xl => 52.0,
      AvatarSize.lg => 44.0,
      AvatarSize.md => 36.0,
      AvatarSize.sm => 28.0,
    };
    final fontSize = switch (size) {
      AvatarSize.xxl => 32.0,
      AvatarSize.xl => 16.0,
      AvatarSize.lg => 14.0,
      AvatarSize.md => 12.0,
      AvatarSize.sm => 10.0,
    };
    final bg = AppColors.avatarColorFor(colorIndex);
    final initialsWidget = Container(
      width: dim,
      height: dim,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      child: Text(
        initials,
        style: GoogleFonts.sora(
          fontSize: fontSize,
          fontWeight: FontWeight.w700,
          color: AppColors.white,
        ),
      ),
    );

    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    final picture = hasImage
        ? ClipOval(
            child: CachedNetworkImage(
              imageUrl: imageUrl!,
              width: dim,
              height: dim,
              fit: BoxFit.cover,
              placeholder: (ctx, url) => initialsWidget,
              errorWidget: (ctx, url, err) => initialsWidget,
              fadeInDuration: const Duration(milliseconds: 120),
            ),
          )
        : initialsWidget;

    final avatar = SizedBox(
      width: dim,
      height: dim,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          picture,
          if (isSelected)
            Positioned(
              top: -2,
              right: -2,
              child: Container(
                width: 18,
                height: 18,
                decoration: BoxDecoration(
                  color: AppColors.medBlue,
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.white, width: 2),
                ),
                child: const Icon(Icons.check, size: 10, color: AppColors.white),
              ),
            )
          else if (presence != null)
            Positioned(bottom: -1, right: -1, child: presence!),
        ],
      ),
    );

    if (heroTag == null) return avatar;
    return Hero(tag: heroTag!, child: avatar);
  }
}

class PresenceStatusDot extends StatelessWidget {
  final Color color;
  const PresenceStatusDot({super.key, required this.color});

  factory PresenceStatusDot.online() => const PresenceStatusDot(color: AppColors.presenceOnline);
  factory PresenceStatusDot.away() => const PresenceStatusDot(color: AppColors.presenceAway);
  factory PresenceStatusDot.offline() => PresenceStatusDot(color: AppColors.presenceOffline);

  /// WhatsApp-style: a dot only while the doctor is online (green) or just
  /// stepped away (amber); offline / unknown / hidden show nothing, so a
  /// doctor who hides their presence is indistinguishable from one offline.
  static PresenceStatusDot? forStatus(PresenceStatus? status) => switch (status) {
        PresenceStatus.online => PresenceStatusDot.online(),
        PresenceStatus.away => PresenceStatusDot.away(),
        _ => null,
      };

  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: AppMotion.maybe(context, AppMotion.micro),
      curve: AppMotion.standard,
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.white, width: 2),
      ),
    );
  }
}
