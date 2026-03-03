import "dart:io";

import "package:flutter/foundation.dart";
import "package:permission_handler/permission_handler.dart";

class StoragePermissionService {
  Future<bool> ensureForLocalRecords() async {
    if (kIsWeb) return true;
    if (!(Platform.isAndroid || Platform.isIOS)) return true;

    if (Platform.isAndroid) {
      PermissionStatus status = await Permission.storage.status;
      if (!status.isGranted) {
        status = await Permission.storage.request();
      }
      if (status.isGranted) return true;
      PermissionStatus manageStatus = await Permission.manageExternalStorage.status;
      if (!manageStatus.isGranted) {
        manageStatus = await Permission.manageExternalStorage.request();
      }
      return manageStatus.isGranted;
    }

    PermissionStatus photos = await Permission.photos.status;
    if (!(photos.isGranted || photos.isLimited)) {
      photos = await Permission.photos.request();
    }
    return photos.isGranted || photos.isLimited;
  }
}
