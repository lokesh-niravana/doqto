import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/tokens/colors.dart';
import '../../core/tokens/spacing.dart';
import '../../core/tokens/typography.dart';
import '../../data/services/chat_cache.dart';
import 'app_text_field.dart';

/// One picker entry from the bundled asset (Unicode 14.0, generated from
/// unicode.org emoji-test.txt). [tones] holds the five single-skin-tone
/// variants when the emoji has them, light → dark.
class EmojiEntry {
  final String emoji;
  final String name;
  final List<String>? tones;

  const EmojiEntry(this.emoji, this.name, this.tones);

  String withTone(int? tone) => tone != null && tones != null ? tones![tone] : emoji;
}

class EmojiGroup {
  final String name;
  final List<EmojiEntry> emoji;
  const EmojiGroup(this.name, this.emoji);
}

/// Loaded once per app run; pure Dart, no plugin (ITMS-90111 risk).
class EmojiCatalog {
  static Future<List<EmojiGroup>>? _loading;

  /// The app's catalog is read once and kept; an explicit [bundle] (tests)
  /// is read fresh so one test's future never leaks into the next.
  static Future<List<EmojiGroup>> load([AssetBundle? bundle]) =>
      bundle != null ? _read(bundle) : (_loading ??= _read(rootBundle));

  static Future<List<EmojiGroup>> _read(AssetBundle bundle) async {
    final raw = await bundle.loadString('assets/emoji/emoji.json');
    return parse(raw);
  }

  static List<EmojiGroup> parse(String raw) {
    final j = jsonDecode(raw) as Map<String, dynamic>;
    return [
      for (final g in j['groups'] as List)
        EmojiGroup(g['name'] as String, [
          for (final e in g['emoji'] as List)
            EmojiEntry(
              e['e'] as String,
              e['n'] as String,
              (e['v'] as List?)?.cast<String>(),
            ),
        ]),
    ];
  }

  /// Name search: every typed word must prefix-match a word of the name.
  static List<EmojiEntry> search(List<EmojiGroup> groups, String query) {
    final words = query.toLowerCase().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).toList();
    if (words.isEmpty) return const [];
    return [
      for (final g in groups)
        for (final e in g.emoji)
          if (_matches(e.name, words)) e,
    ];
  }

  static bool _matches(String name, List<String> words) {
    final parts = name.toLowerCase().split(RegExp(r'[^a-z0-9]+'));
    return words.every((w) => parts.any((p) => p.startsWith(w)));
  }
}

const _groupIcons = <String, IconData>{
  'Smileys & Emotion': Icons.emoji_emotions_outlined,
  'People & Body': Icons.back_hand_outlined,
  'Animals & Nature': Icons.pets_outlined,
  'Food & Drink': Icons.local_cafe_outlined,
  'Travel & Places': Icons.directions_car_outlined,
  'Activities': Icons.sports_soccer_outlined,
  'Objects': Icons.lightbulb_outline,
  'Symbols': Icons.emoji_symbols_outlined,
  'Flags': Icons.flag_outlined,
};

/// Full picker in a bottom sheet. Resolves with the chosen emoji (already
/// pushed to Recent), or null when dismissed.
Future<String?> showEmojiPickerSheet(BuildContext context, ChatCache cache) {
  return showModalBottomSheet<String>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => EmojiPickerSheet(cache: cache),
  );
}

class EmojiPickerSheet extends StatefulWidget {
  final ChatCache cache;
  final AssetBundle? bundle;
  const EmojiPickerSheet({super.key, required this.cache, this.bundle});

  @override
  State<EmojiPickerSheet> createState() => _EmojiPickerSheetState();
}

class _EmojiPickerSheetState extends State<EmojiPickerSheet> {
  final _search = TextEditingController();
  final _focus = FocusNode();
  late final Future<List<EmojiGroup>> _groups = EmojiCatalog.load(widget.bundle);
  late final List<String> _recent = widget.cache.recentEmoji();
  late int? _tone = widget.cache.skinTone();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _pick(String emoji) async {
    HapticFeedback.lightImpact();
    await widget.cache.pushRecentEmoji(emoji);
    if (mounted) Navigator.pop(context, emoji);
  }

  Future<void> _pickTone(EmojiEntry e) async {
    final tones = e.tones;
    if (tones == null) return;
    final choice = await showDialog<int>(
      context: context,
      builder: (ctx) => SimpleDialog(
        title: const Text('Skin tone'),
        children: [
          Wrap(
            alignment: WrapAlignment.center,
            children: [
              for (var i = -1; i < 5; i++)
                InkResponse(
                  key: ValueKey('tone-$i'),
                  onTap: () => Navigator.pop(ctx, i),
                  child: Padding(
                    padding: const EdgeInsets.all(AppSpacing.sm),
                    child: Text(
                      i < 0 ? e.emoji : tones[i],
                      style: const TextStyle(fontSize: 32),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
    if (choice == null) return;
    final tone = choice < 0 ? null : choice;
    await widget.cache.setSkinTone(tone);
    setState(() => _tone = tone);
    await _pick(e.withTone(tone));
  }

  @override
  Widget build(BuildContext context) {
    final height = MediaQuery.sizeOf(context).height * 0.6;
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    return Padding(
      padding: EdgeInsets.only(bottom: inset),
      child: SizedBox(
        height: height,
        child: FutureBuilder<List<EmojiGroup>>(
          future: _groups,
          builder: (context, snap) {
            final groups = snap.data;
            return Column(
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(
                    AppSpacing.lg, 0, AppSpacing.lg, AppSpacing.sm,
                  ),
                  child: AppTextField(
                    key: const ValueKey('emoji-search'),
                    controller: _search,
                    focusNode: _focus,
                    hint: 'Search emoji',
                    onChanged: (v) => setState(() => _query = v.trim()),
                  ),
                ),
                if (groups == null)
                  const Expanded(child: Center(child: CircularProgressIndicator()))
                else if (_query.isNotEmpty)
                  Expanded(child: _searchResults(groups))
                else
                  Expanded(child: _tabs(groups)),
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _searchResults(List<EmojiGroup> groups) {
    final hits = EmojiCatalog.search(groups, _query);
    if (hits.isEmpty) {
      return Center(
        child: Text('No emoji found', style: AppText.body.copyWith(color: AppColors.gray600)),
      );
    }
    return _grid(hits);
  }

  Widget _tabs(List<EmojiGroup> groups) {
    final showRecent = _recent.isNotEmpty;
    return DefaultTabController(
      length: groups.length + (showRecent ? 1 : 0),
      child: Column(
        children: [
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelColor: AppColors.medBlue,
            unselectedLabelColor: AppColors.gray400,
            indicatorColor: AppColors.medBlue,
            tabs: [
              if (showRecent)
                const Tab(icon: Icon(Icons.access_time), height: 40),
              for (final g in groups)
                Tab(
                  icon: Icon(_groupIcons[g.name] ?? Icons.circle_outlined),
                  height: 40,
                ),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                if (showRecent)
                  _grid([for (final e in _recent) EmojiEntry(e, 'recent', null)]),
                for (final g in groups) _grid(g.emoji),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _grid(List<EmojiEntry> items) {
    return GridView.builder(
      keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
      padding: const EdgeInsets.symmetric(horizontal: AppSpacing.sm, vertical: AppSpacing.xs),
      gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
        maxCrossAxisExtent: 48,
      ),
      itemCount: items.length,
      itemBuilder: (_, i) {
        final e = items[i];
        final shown = e.withTone(_tone);
        return Semantics(
          button: true,
          label: e.name,
          child: InkResponse(
            key: ValueKey('emoji-$shown'),
            onTap: () => _pick(shown),
            onLongPress: e.tones == null ? null : () => _pickTone(e),
            child: Center(
              child: ExcludeSemantics(
                child: Text(shown, style: const TextStyle(fontSize: 28)),
              ),
            ),
          ),
        );
      },
    );
  }
}
