import 'package:flutter/material.dart';

import '../services/gbear_stream_foreground.dart';
import '../services/stream_shortcuts_store.dart';
import 'companion_insets.dart';

/// Tap-to-send shortcut list (used when the video overlay is not open).
Future<void> showStreamShortcutsPickerSheet(BuildContext context) async {
  final store = await StreamShortcutsStore.load();
  final shortcuts = store.shortcuts;
  if (!context.mounted) return;

  await showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (sheetContext) {
      return Padding(
        padding: EdgeInsets.only(bottom: CompanionInsets.sheetBottom(sheetContext)),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Text(
                'Shortcuts',
                style: Theme.of(sheetContext).textTheme.titleMedium,
              ),
            ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 8, 16, 8),
              child: Text('Tap a shortcut to send it to your Mac.'),
            ),
            if (shortcuts.isEmpty)
              const Padding(
                padding: EdgeInsets.all(24),
                child: Text('No shortcuts. Add them in Settings.'),
              )
            else
              Flexible(
                child: ListView.builder(
                  shrinkWrap: true,
                  itemCount: shortcuts.length,
                  itemBuilder: (context, index) {
                    final shortcut = shortcuts[index];
                    return ListTile(
                      title: Text(shortcut.name),
                      subtitle: Text(shortcut.keyLabel),
                      onTap: () async {
                        final ok = await GBearStreamNotification.fireStreamShortcut(
                          shortcut.moonlightKeyCodes,
                        );
                        if (sheetContext.mounted) {
                          Navigator.pop(sheetContext);
                          if (!ok) {
                            ScaffoldMessenger.of(sheetContext).showSnackBar(
                              const SnackBar(
                                content: Text(
                                  'Could not send shortcut. Start a stream first.',
                                ),
                              ),
                            );
                          }
                        }
                      },
                    );
                  },
                ),
              ),
          ],
        ),
      );
    },
  );
}
