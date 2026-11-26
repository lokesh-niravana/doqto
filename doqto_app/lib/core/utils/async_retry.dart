import 'package:flutter_riverpod/flutter_riverpod.dart';

extension AsyncRetry<T> on AsyncValue<T> {
  /// [AsyncValue.when] for a pane whose Retry button invalidates the
  /// provider.
  ///
  /// Invalidating an errored provider leaves it an `AsyncError` with
  /// `isLoading` set, and plain `when` (skipLoadingOnRefresh) keeps drawing
  /// the error pane: Retry looked like it did nothing until the answer came
  /// back. This shows [loading] again for that stretch, so the tap is
  /// acknowledged on screen and — the loading widgets carry a "Loading" label
  /// — to VoiceOver.
  R whenRetrying<R>({
    bool skipLoadingOnReload = false,
    bool skipLoadingOnRefresh = true,
    required R Function(T data) data,
    required R Function(Object error, StackTrace stackTrace) error,
    required R Function() loading,
  }) =>
      when(
        skipLoadingOnReload: skipLoadingOnReload,
        skipLoadingOnRefresh: skipLoadingOnRefresh,
        data: data,
        error: (e, st) => isLoading ? loading() : error(e, st),
        loading: loading,
      );
}
