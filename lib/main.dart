import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'engine.dart';
import 'icon_store.dart';
import 'native_bridge.dart';
import 'theme.dart';
import 'ui/shell.dart';

void _log(String where, Object e, [StackTrace? st]) {
  final line = '[$where] $e${st == null ? '' : '\n$st'}';
  final cur = engine.errorLog;
  if (cur != null && cur.contains(line)) return;
  engine.errorLog = cur == null ? line : '$cur\n\n$line';
}

Future<void> main() async {
  await runZonedGuarded<Future<void>>(() async {
    WidgetsFlutterBinding.ensureInitialized();
    FlutterError.onError = (FlutterErrorDetails d) {
      final msg = d.exceptionAsString();
      // Icones de jetons introuvables (403/404) : normal, l'application affiche une pastille a la place.
      if (msg.contains('HTTP request failed') || d.exception.runtimeType.toString().contains('NetworkImageLoadException')) {
        return;
      }
      FlutterError.presentError(d);
      _log('flutter', msg, d.stack);
    };
    ErrorWidget.builder = (FlutterErrorDetails d) => Container(
          padding: const EdgeInsets.all(8),
          color: const Color(0xFF2B1B1B),
          child: Text('Erreur : \n${d.exceptionAsString()}',
              style: const TextStyle(color: Colors.white, fontSize: 11)),
        );
    try {
      await engine.init().timeout(const Duration(seconds: 12));
    } catch (e, st) {
      _log('init', e, st);
    }
    try {
      await IconStore.I.init().timeout(const Duration(seconds: 8));
    } catch (e, st) {
      _log('icones', e, st);
    }
    runApp(const CryptoRadarApp());
    // Crash natif de la session precedente (ecrit par le code Android)
    try {
      final c = await NativeBridge.getCrash();
      if (c != null && c.isNotEmpty) _log('crash natif precedent', c);
    } catch (_) {}
  }, (Object e, StackTrace st) {
    // Erreurs reseau transitoires (socket fermee, DNS, delai depasse...) : on les memorise pour le diagnostic
    // reseau, sans polluer le journal d'erreurs.
    final isNet = e is SocketException ||
        e is HttpException ||
        e is WebSocketException ||
        e is HandshakeException ||
        e is TlsException ||
        e is TimeoutException ||
        e.runtimeType.toString().contains('ClientException');
    if (isNet) {
      final t = '$e';
      engine.lastNetErr = t.length > 140 ? t.substring(0, 140) : t;
      return;
    }
    _log('zone', e, st);
  });
}

class CryptoRadarApp extends StatelessWidget {
  const CryptoRadarApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Crypto Radar',
      debugShowCheckedModeBanner: false,
      theme: buildTheme(),
      home: const Shell(),
    );
  }
}
