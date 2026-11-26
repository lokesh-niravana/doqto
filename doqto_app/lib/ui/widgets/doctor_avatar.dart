import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../core/constants/strings.dart';
import '../../core/enums/app_enums.dart';
import '../../core/utils/avatar_urls.dart';
import '../../data/api/token_storage.dart';
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

  /// Initials colour for an avatar [fill]: white, unless white is under 3:1
  /// on it (bright teal, amber, any light fill), then near-black.
  static Color initialsColorOn(Color fill) {
    final whiteContrast = 1.05 / (fill.computeLuminance() + 0.05);
    return whiteContrast < 3 ? AppColors.gray900 : AppColors.white;
  }

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
      AvatarSize.sm => 11.0,
    };
    final bg = AppColors.avatarColorFor(colorIndex);
    final initialsWidget = Container(
      width: dim,
      height: dim,
      alignment: Alignment.center,
      decoration: BoxDecoration(color: bg, shape: BoxShape.circle),
      // The circle is a fixed size; at large text sizes the initials scale
      // down to fit inside it instead of clipping at its edge.
      padding: EdgeInsets.all(dim * 0.12),
      // Drawn only. The person's name is beside the avatar (or is the
      // label of the control wrapping it); read aloud, "PS, Priya Shah" says
      // the same thing twice, the first time as two letters.
      child: ExcludeSemantics(
        child: FittedBox(
          fit: BoxFit.scaleDown,
          child: Text(
            initials,
            maxLines: 1,
            softWrap: false,
            style: GoogleFonts.sora(
              fontSize: fontSize,
              fontWeight: FontWeight.w700,
              color: initialsColorOn(bg),
            ),
          ),
        ),
      ),
    );

    final hasImage = imageUrl != null && imageUrl!.isNotEmpty;
    // Pictures served by our API (see avatar_urls.dart) need the bearer
    // token; S3 presigned links carry their own credential in the query.
    final token = TokenStorage.cachedAccessToken;
    final headers = hasImage && isApiImageUrl(imageUrl!) && token != null
        ? {'Authorization': 'Bearer $token'}
        : null;
    final picture = hasImage
        ? ClipOval(
            child: CachedNetworkImage(
              imageUrl: imageUrl!,
              httpHeaders: headers,
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
              child: Semantics(
                label: Strings.a11ySelected,
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

  /// Drawn as a ring (white centre) instead of a filled dot, so "away" differs
  /// from "online" by shape and not only by hue.
  final bool hollow;

  /// Spoken state. The two dots that are drawn (online, away) are named;
  /// offline draws nothing and says nothing, as it does for a doctor who
  /// hides presence.
  final String? semanticLabel;
  const PresenceStatusDot({super.key, required this.color, this.semanticLabel, this.hollow = false});

  // Against the dot's white outer ring: greenDark is 5.02:1 (green was
  // 2.28:1) and amberText 7.09:1 (amber was 2.15:1).
  factory PresenceStatusDot.online() =>
      PresenceStatusDot(color: AppColors.greenDark, semanticLabel: Strings.a11yOnline);
  factory PresenceStatusDot.away() =>
      PresenceStatusDot(color: AppColors.amberText, semanticLabel: Strings.a11yAway, hollow: true);
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
    // 10pt overall with a 2pt white outer ring. Online fills the 6pt centre;
    // away draws a 1.5pt coloured ring around a white 3pt centre.
    final dot = AnimatedContainer(
      duration: AppMotion.maybe(context, AppMotion.micro),
      curve: AppMotion.standard,
      width: 10,
      height: 10,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: AppColors.white, width: 2),
      ),
      alignment: Alignment.center,
      child: hollow
          ? Container(
              width: 3,
              height: 3,
              decoration: const BoxDecoration(color: AppColors.white, shape: BoxShape.circle),
            )
          : null,
    );
    // Give each drawn state a name as well.
    if (semanticLabel == null) return ExcludeSemantics(child: dot);
    return Semantics(label: semanticLabel, child: dot);
  }
}
