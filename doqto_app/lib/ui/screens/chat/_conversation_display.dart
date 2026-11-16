import '../../../core/enums/app_enums.dart';
import '../../../data/models/conversation.dart';
import '../../../data/models/organization.dart';

class ConversationDisplay {
  final String title;
  final OrgMember? otherUser;   // direct: the other member; group/unknown: null
  final bool isDirect;
  final int colorIndex;    // for fallback DoctorAvatar
  final String initials;

  const ConversationDisplay({
    required this.title,
    required this.otherUser,
    required this.isDirect,
    required this.colorIndex,
    required this.initials,
  });
}

String _initialsFor(String name) {
  final parts = name.trim().split(RegExp(r'\s+'));
  return parts.length >= 2
      ? (parts[0][0] + parts[1][0]).toUpperCase()
      : name.substring(0, name.length.clamp(0, 2)).toUpperCase();
}

/// Derive a display-ready title/avatar bundle for a conversation.
///
/// - Direct: finds the OTHER member in `orgMembers` and uses their profile.
/// - Group: uses `c.name` as title with generated initials.
ConversationDisplay conversationDisplay({
  required Conversation c,
  required List<OrgMember> orgMembers,
  required String? meId,
  required int fallbackColorIndex,
}) {
  // Tolerant (A5): anything that isn't explicitly a group — including
  // ConversationType.unknown — renders through the direct path, which has
  // safe fallbacks (server displayName → 'Direct chat').
  if (c.type != ConversationType.group) {
    String? otherId;
    for (final id in c.memberIds) {
      if (id != meId) {
        otherId = id;
        break;
      }
    }
    OrgMember? otherMember;
    if (otherId != null) {
      for (final m in orgMembers) {
        if (m.id == otherId) {
          otherMember = m;
          break;
        }
      }
    }
    if (otherMember != null) {
      return ConversationDisplay(
        title: otherMember.fullName,
        otherUser: otherMember,
        isDirect: true,
        colorIndex: fallbackColorIndex,
        initials: otherMember.initials,
      );
    }
    // Server-resolved peer name — covers peers missing from the org-members cache.
    final serverName = c.displayName?.trim();
    if (serverName != null && serverName.isNotEmpty) {
      return ConversationDisplay(
        title: serverName,
        otherUser: null,
        isDirect: true,
        colorIndex: fallbackColorIndex,
        initials: _initialsFor(serverName),
      );
    }
    return ConversationDisplay(
      title: 'Direct chat',
      otherUser: null,
      isDirect: true,
      colorIndex: fallbackColorIndex,
      initials: '•',
    );
  }
  // Group (or anything else).
  final name = (c.name == null || c.name!.trim().isEmpty) ? 'Group' : c.name!;
  final initials = _initialsFor(name);
  return ConversationDisplay(
    title: name,
    otherUser: null,
    isDirect: false,
    colorIndex: fallbackColorIndex,
    initials: initials,
  );
}

/// The other member of a direct conversation (null for groups / unknown).
String? directPeerId(Conversation c, String? meId) {
  if (c.type == ConversationType.group) return null;
  for (final id in c.memberIds) {
    if (id != meId) return id;
  }
  return null;
}
