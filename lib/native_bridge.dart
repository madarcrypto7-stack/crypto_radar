import 'package:flutter/services.dart';

class NativeBridge {
  static const MethodChannel _ch = MethodChannel('crypto_radar/native');

  static Future<void> _call(String m, [Map<String, dynamic>? args]) async {
    try {
      await _ch.invokeMethod<dynamic>(m, args);
    } catch (_) {}
  }

  static Future<String?> getCrash() async {
    try {
      return await _ch.invokeMethod<String>('getCrash');
    } catch (_) {
      return null;
    }
  }

  /// Enregistre un fichier dans Telechargements. Retourne le chemin, ou null en cas d'echec.
  static Future<String?> saveFile(String name, String mime, String content) async {
    try {
      return await _ch.invokeMethod<String>(
        'saveFile',
        <String, dynamic>{'name': name, 'mime': mime, 'content': content},
      );
    } catch (_) {
      return null;
    }
  }

  static Future<void> requestPermission() => _call('requestPermission');
  static Future<void> notify(String title, String body) =>
      _call('notify', <String, dynamic>{'title': title, 'body': body});
  static Future<void> startService() => _call('startService');
  static Future<void> stopService() => _call('stopService');
}
