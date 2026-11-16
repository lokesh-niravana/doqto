import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../../core/tokens/colors.dart';
import '../../../state/groups_state.dart';
import '../chat/chat_thread_screen.dart';
import '../../widgets/app_skeleton.dart';
import 'group_info_screen.dart';

/// A group opens as its chat, full screen like any conversation; the header
/// leads to Group info. Someone who can't read the chat (a pending invite)
/// gets Group info straight away.
class GroupDetailScreen extends ConsumerWidget {
  final String groupId;
  const GroupDetailScreen({super.key, required this.groupId});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final group = ref.watch(groupDetailProvider(groupId)).asData?.value;
    if (group == null) {
      // Loading or failed: Group info shows both, with retry.
      return ref.watch(groupDetailProvider(groupId)).isLoading
          ? Scaffold(
              backgroundColor: AppColors.appBg,
              body: const SafeArea(child: SkeletonList()),
            )
          : GroupInfoScreen(groupId: groupId);
    }
    if (!group.isMember || group.conversationId.isEmpty) {
      return GroupInfoScreen(groupId: groupId);
    }
    return ChatThreadScreen(
      conversationId: group.conversationId,
      groupId: group.id,
    );
  }
}
