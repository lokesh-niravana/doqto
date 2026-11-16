import 'package:flutter/material.dart';

import '../../core/tokens/colors.dart';
import '../../core/utils/rich_text.dart';

/// Composer controller for @mentions (batch 4). The field shows `@Dr Name`
/// as a tinted chip; the wire form sent to the server is `@[<user uuid>]`.
/// Keeping the display text in the controller (not the token) means the
/// caret and selection always line up with what is on screen; the chip is
/// just a styled span over the name.
class MentionController extends TextEditingController {
  MentionController({super.text});

  /// display name (with the leading @) → user id, for every mention inserted
  /// or restored into this composer.
  final Map<String, String> _byDisplay = {};

  static String displayFor(String name) => '@${name.trim()}';

  /// The `@query` the caret is inside, or null when there is none. [query] is
  /// the text typed after the @ (may be empty); [start] is the @'s offset.
  ({String query, int start})? activeMention() {
    final sel = selection;
    if (!sel.isValid || !sel.isCollapsed) return null;
    final head = text.substring(0, sel.end);
    final at = head.lastIndexOf('@');
    if (at < 0) return null;
    if (at > 0 && RegExp(r'[\p{L}\p{N}]', unicode: true).hasMatch(head[at - 1])) {
      return null; // an email-ish "a@b"
    }
    final query = head.substring(at + 1);
    if (query.contains('\n') || query.length > 40) return null;
    // Inside or right after a completed chip? Then no autocomplete.
    for (final d in _byDisplay.keys) {
      if (head.substring(at).startsWith(d)) return null;
    }
    return (query: query, start: at);
  }

  /// Replace the active `@query` with a chip for [name] / [userId].
  void insertMention({required String userId, required String name}) {
    final active = activeMention();
    final display = displayFor(name);
    _byDisplay[display] = userId;
    final sel = selection;
    final start = active?.start ?? (sel.isValid ? sel.end : text.length);
    final end = sel.isValid ? sel.end : text.length;
    final next = '${text.substring(0, start)}$display ${text.substring(end)}';
    value = TextEditingValue(
      text: next,
      selection: TextSelection.collapsed(offset: start + display.length + 1),
    );
  }

  /// What goes on the wire: every chip becomes `@[uuid]`.
  String get wireText {
    var out = text;
    // Longest names first so "Dr Ann" never clobbers "Dr Ann Lee".
    final names = _byDisplay.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
    for (final d in names) {
      out = out.replaceAll(d, '@[${_byDisplay[d]}]');
    }
    return out;
  }

  /// Load [wire] (tokens) into the composer as chips, resolving names with
  /// [nameFor] (unknown ids keep their token).
  void setFromWire(String wire, String? Function(String userId) nameFor) {
    final shown = wire.replaceAllMapped(mentionTokenPattern, (m) {
      final id = m.group(1)!.toLowerCase();
      final name = nameFor(id);
      if (name == null) return m.group(0)!;
      final display = displayFor(name);
      _byDisplay[display] = id;
      return display;
    });
    value = TextEditingValue(
      text: shown,
      selection: TextSelection.collapsed(offset: shown.length),
    );
  }

  /// Ids of the chips still present in the text.
  List<String> get mentionedIds => [
        for (final e in _byDisplay.entries)
          if (text.contains(e.key)) e.value,
      ];

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final present = _byDisplay.keys.where(text.contains).toList()
      ..sort((a, b) => b.length.compareTo(a.length));
    if (present.isEmpty) {
      return super.buildTextSpan(context: context, style: style, withComposing: withComposing);
    }
    final chip = (style ?? const TextStyle()).copyWith(
      color: AppColors.medBlue,
      fontWeight: FontWeight.w600,
      backgroundColor: AppColors.medBlueLight,
    );
    final children = <InlineSpan>[];
    var pos = 0;
    while (pos < text.length) {
      var nextStart = -1;
      String? hit;
      for (final d in present) {
        final i = text.indexOf(d, pos);
        if (i >= 0 && (nextStart < 0 || i < nextStart)) {
          nextStart = i;
          hit = d;
        }
      }
      if (hit == null) {
        children.add(TextSpan(text: text.substring(pos)));
        break;
      }
      if (nextStart > pos) children.add(TextSpan(text: text.substring(pos, nextStart)));
      children.add(TextSpan(text: hit, style: chip));
      pos = nextStart + hit.length;
    }
    return TextSpan(style: style, children: children);
  }
}
