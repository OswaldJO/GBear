import 'package:flutter/foundation.dart';

/// Stream pipeline logs for `flutter run` (Dart only — iOS native uses NSLog / `flutter logs`).
void gbearStreamDebug(String message) {
  debugPrint('[GBearStream] $message');
}
