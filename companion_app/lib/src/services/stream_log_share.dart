import 'dart:io';

import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

/// Offers to share the native stream debug log after a session ends.
Future<void> offerStreamLogShare(BuildContext context, String logPath) async {
  if (!Platform.isAndroid && !Platform.isIOS) return;
  final file = File(logPath);
  if (!await file.exists()) return;

  if (!context.mounted) return;
  final shouldShare = await showDialog<bool>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('Send stream debug log?'),
      content: const Text(
        'The last streaming session was saved to a text log on this phone. '
        'You can email it (or share it another way) to help debug connection or video issues.',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx, false),
          child: const Text('Not now'),
        ),
        FilledButton(
          onPressed: () => Navigator.pop(ctx, true),
          child: const Text('Email log'),
        ),
      ],
    ),
  );

  if (shouldShare != true || !context.mounted) return;

  await Share.shareXFiles(
    [XFile(logPath, mimeType: 'text/plain', name: 'gbear_stream.log')],
    subject: 'GBear companion stream log',
    text: 'GBear companion stream debug log.',
  );
}
