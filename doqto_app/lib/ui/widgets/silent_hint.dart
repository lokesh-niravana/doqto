import 'package:flutter/material.dart';

/// A text field's placeholder, drawn but not read aloud.
///
/// For a field whose accessible name comes from a `Semantics(label:)` around
/// it rather than from a visible label. `InputDecoration.hintText` is merged
/// into that name while the field is empty ("Search, Search", or
/// "Verification code, 000000") and vanishes once something is typed; this
/// keeps the name the same throughout. Pass as `InputDecoration.hint`.
class SilentHint extends StatelessWidget {
  final String text;

  /// The field's own text style, which a hint inherits its size from.
  final TextStyle? fieldStyle;

  /// Overrides the theme's hint style (colour, mostly).
  final TextStyle? style;
  final int? maxLines;

  const SilentHint(
    this.text, {
    super.key,
    this.fieldStyle,
    this.style,
    this.maxLines = 1,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // The same chain InputDecorator applies to `hintText`.
    final resolved = (theme.textTheme.bodyLarge ?? const TextStyle())
        .merge(fieldStyle)
        // No app-font fallback: some dialogs run under a bare theme (and in
        // tests, where the app font cannot be fetched).
        .merge(
          theme.inputDecorationTheme.hintStyle ??
              TextStyle(color: theme.colorScheme.onSurfaceVariant),
        )
        .merge(style);
    return ExcludeSemantics(
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: resolved,
      ),
    );
  }
}
