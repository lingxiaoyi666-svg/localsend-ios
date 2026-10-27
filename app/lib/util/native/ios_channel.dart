import 'dart:async';

import 'package:flutter/services.dart';

const _methodChannel = MethodChannel('ios-delegate-channel');

Future<bool> isReduceMotionEnabledIOS() async {
  return await _methodChannel.invokeMethod('isReduceMotionEnabled') ?? false;
}

/// Opens the iOS folder picker (UIDocumentPickerViewController in folder mode)
/// and returns the raw path of the picked folder, or `null` when cancelled.
///
/// file_picker is not used here because it does not keep the security scope,
/// which would make every write outside of the app sandbox fail.
Future<String?> pickDirectoryPathIos() async {
  return await _methodChannel.invokeMethod<String>('pickDirectory');
}

/// Stores a security scoped bookmark for [path] so that the folder stays
/// writable after the app has been restarted.
Future<bool> persistDestinationFolderAccessIos(String path) async {
  return await _methodChannel.invokeMethod<bool>('persistDestinationFolderAccess', path) ?? false;
}

/// Forgets the stored bookmark (the destination was reset to the app folder).
Future<bool> removeExistingDestinationAccessIos() async {
  return await _methodChannel.invokeMethod<bool>('removeDestinationFolderAccess') ?? false;
}

Future<bool> hasPersistedDestinationAccessIos() async {
  return await _methodChannel.invokeMethod<bool>('hasDestinationFolderAccess') ?? false;
}
