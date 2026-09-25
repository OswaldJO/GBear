import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:share_plus/share_plus.dart';

import 'stream_controller_mapping_store.dart';
import 'stream_controller_profile_export.dart';
import 'stream_controller_profile_store.dart';

/// Export / import controller mapping profiles as JSON files.
abstract final class StreamControllerProfileShare {
  static Future<void> exportActiveProfile(
    BuildContext context, {
    required StreamControllerProfile profile,
  }) async {
    final json = StreamControllerProfileExport.encode(profile);
    final fileName =
        'gbear_controller_${StreamControllerProfileExport.sanitizeFileName(profile.name)}.json';
    final dir = await Directory.systemTemp.createTemp('gbear_profile_');
    final file = File('${dir.path}/$fileName');
    await file.writeAsString(json);
    if (!context.mounted) return;
    await Share.shareXFiles(
      [XFile(file.path, mimeType: 'application/json', name: fileName)],
      subject: 'GBear controller profile: ${profile.name}',
      text: 'GBear companion controller mapping profile.',
    );
  }

  static Future<StreamControllerProfileImportResult?> pickAndParse(
    BuildContext context,
  ) async {
    final result = await FilePicker.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['json'],
      withData: true,
    );
    if (result == null || result.files.isEmpty) return null;
    final file = result.files.single;
    final bytes = file.bytes;
    final path = file.path;
    String raw;
    if (bytes != null) {
      raw = String.fromCharCodes(bytes);
    } else if (path != null) {
      raw = await File(path).readAsString();
    } else {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not read the selected file')),
        );
      }
      return null;
    }
    try {
      final profile = StreamControllerProfileExport.parse(raw);
      return StreamControllerProfileImportResult(profile: profile);
    } on FormatException catch (e) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Invalid profile file: ${e.message}')),
        );
      }
      return null;
    }
  }

  static Future<void> importAsNewProfile(
    BuildContext context, {
    required StreamControllerProfile imported,
    String? nameOverride,
  }) async {
    final store = await StreamControllerMappingStore.load();
    final name = nameOverride?.trim().isNotEmpty == true
        ? nameOverride!.trim()
        : imported.name.trim().isEmpty
            ? 'Imported profile'
            : imported.name.trim();
    final id = await store.createProfile(
      name: name,
      copyFromActive: false,
    );
    await store.profileStore.importBindings(id, imported.bindings);
    await store.activateProfile(id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Imported and loaded "$name"')),
      );
    }
  }

  static Future<void> replaceActiveProfile(
    BuildContext context, {
    required StreamControllerProfile imported,
  }) async {
    final store = await StreamControllerMappingStore.load();
    final active = store.activeProfile;
    if (active == null) return;
    await store.profileStore.importBindings(active.id, imported.bindings);
    await store.activateProfile(active.id);
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('Replaced mappings in "${active.name}"')),
      );
    }
  }
}

class StreamControllerProfileImportResult {
  const StreamControllerProfileImportResult({required this.profile});

  final StreamControllerProfile profile;
}
