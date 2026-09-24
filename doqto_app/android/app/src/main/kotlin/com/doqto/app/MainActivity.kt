package com.doqto.app

import io.flutter.embedding.android.FlutterActivity

// No FLAG_SECURE (owner's decision, 2026-09-25). It blanked every screenshot,
// so Play review's capture saw only the launch screen and rejected the app as
// "does not load" (2026-09-13). iOS has no equivalent. If screenshot blocking
// becomes a requirement, add it back on the chat screens only.
class MainActivity : FlutterActivity()
