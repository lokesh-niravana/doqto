import 'package:url_launcher/url_launcher.dart';

/// Opens a URL outside the app. An interface, so widget tests never launch a
/// real browser.
abstract class UrlOpener {
  Future<bool> open(String url);
}

class ExternalUrlOpener implements UrlOpener {
  const ExternalUrlOpener();

  @override
  Future<bool> open(String url) => launchUrl(
        Uri.parse(url),
        // externalApplication, not an in-app web view: Apple's link-out rule
        // for web payments requires the real browser.
        mode: LaunchMode.externalApplication,
      );
}

class FakeUrlOpener implements UrlOpener {
  final List<String> opened = [];
  bool result = true;

  @override
  Future<bool> open(String url) async {
    opened.add(url);
    return result;
  }
}
