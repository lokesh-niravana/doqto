import 'package:flutter/material.dart';

import '../../data/models/network_profile.dart';
import 'app_pill.dart';
import 'doctor_avatar.dart';
import 'member_row.dart';

/// A [MemberRow] bound to a [PersonCard] — avatar (hero-paired on
/// `member-avatar-<id>`), name, headline/specialty subtitle, and a trailing
/// slot that defaults to the person's [DegreeBadge]. Shared by the Network tab,
/// connections, and people-search lists.
class PersonCardRow extends StatelessWidget {
  final PersonCard person;
  final VoidCallback? onTap;
  final VoidCallback? onLongPress;

  /// Overrides the default degree-badge trailing (e.g. a Connect button or a
  /// message ghost icon). When null, the degree badge is shown (if any).
  final Widget? trailing;

  /// Replaces the headline/specialty line (e.g. why a doctor is suggested).
  final String? subtitle;

  const PersonCardRow({
    super.key,
    required this.person,
    this.onTap,
    this.onLongPress,
    this.trailing,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final subtitle =
        this.subtitle ?? _firstNonEmpty([person.headline, person.specialty]);
    final row = MemberRow(
      avatar: DoctorAvatar(
        initials: person.initials,
        colorIndex: person.avatarIndex,
        imageUrl: person.avatarPresignedUrl,
        size: AvatarSize.lg,
        heroTag: 'member-avatar-${person.id}',
      ),
      title: person.fullName,
      subtitle: subtitle,
      trailing: trailing ?? DegreeBadge.forDegree(person.degree),
      onTap: onTap,
    );
    if (onLongPress == null) return row;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onLongPress: onLongPress,
      child: row,
    );
  }

  static String? _firstNonEmpty(List<String?> options) {
    for (final o in options) {
      if (o != null && o.trim().isNotEmpty) return o;
    }
    return null;
  }
}
