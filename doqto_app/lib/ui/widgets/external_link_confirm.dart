import 'package:flutter/material.dart';

import '../../core/constants/strings.dart';
import '../../core/tokens/typography.dart';
import '../../data/services/url_opener.dart';

/// Ask before leaving the app for a link or a call (batch 4). Returns true
/// when the doctor confirmed and the opener accepted the URL.
Future<bool> confirmAndOpenExternal(
  BuildContext context, {
  required String url,
  required UrlOpener opener,
  bool isPhone = false,
}) async {
  final ok = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      key: const ValueKey('open-link-dialog'),
      title: Text(isPhone ? Strings.chatCallNumberTitle : Strings.chatOpenLinkTitle),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SelectableText(
            isPhone ? url.replaceFirst('tel:', '') : url,
            style: AppText.bodyPrimary,
            maxLines: 4,
          ),
          if (!isPhone) ...[
            const SizedBox(height: 8),
            Text(Strings.chatOpenLinkBody, style: AppText.caption),
          ],
        ],
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text(Strings.cancel)),
        TextButton(
          key: const ValueKey('open-link-confirm'),
          onPressed: () => Navigator.pop(ctx, true),
          child: Text(isPhone ? 'Call' : Strings.chatOpenLink),
        ),
      ],
    ),
  );
  if (ok != true) return false;
  return opener.open(url);
}
