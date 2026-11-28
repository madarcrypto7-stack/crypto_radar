import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:sqflite/sqflite.dart';

/// Cle d'icone d'un jeton : "1000PEPE" -> "PEPE", "1MBABYDOGE" -> "BABYDOGE".
String iconKey(String base) {
  var b = base.toUpperCase();
  for (final p in const <String>['1000000', '100000', '10000', '1000']) {
    if (b.startsWith(p) && b.length > p.length) {
      b = b.substring(p.length);
      break;
    }
  }
  if (b.startsWith('1M') && b.length > 2) b = b.substring(2);
  return b;
}

class _Job {
  _Job(this.base, this.kind);
  final String base;
  final int kind; // 0 = nouveau jeton, 1 = nouvelle tentative (icone manquante), 2 = revalidation, 3 = source CoinGecko seule
}

/// Base de donnees locale (SQLite) des icones de jetons.
/// - Telechargement unique de toutes les icones au premier demarrage, redimensionnees a [px] pixels (PNG).
/// - Verification des mises a jour aupres de la source une fois par jour (requete conditionnelle ETag quand c'est possible).
/// - L'affichage ne fait plus aucune requete reseau : tout est lu en memoire depuis la base.
class IconStore extends ChangeNotifier {
  IconStore._();
  static final IconStore I = IconStore._();

  /// Taille de stockage des icones (pixels). 96 px reste net jusqu'a ~32 dp sur un ecran 3x.
  static const int px = 96;
  static const int dayMs = 86400000;

  Database? _db;
  final http.Client _http = http.Client();
  final Map<String, Uint8List> mem = <String, Uint8List>{};
  final Set<String> missing = <String>{};
  final Map<String, int> _updated = <String, int>{};
  final Map<String, String> _src = <String, String>{};
  final Map<String, String> _etag = <String, String>{};
  final ValueNotifier<String> progress = ValueNotifier<String>('');
  bool _syncing = false;
  final Map<String, String> _cg = <String, String>{}; // symbole -> URL d'image CoinGecko (plus forte capitalisation)
  int cgLast = 0;
  int get cgCount => _cg.length;
  int lastCheck = 0;

  int get count => mem.length;
  int get missingCount => missing.length;

  Future<void> init() async {
    try {
      final dir = await getDatabasesPath();
      final db = await openDatabase(
        '$dir/token_icons.db',
        version: 2,
        onCreate: (Database d, int v) async {
          await d.execute(
            'CREATE TABLE icons(base TEXT PRIMARY KEY, png BLOB, status INTEGER NOT NULL, src TEXT, etag TEXT, updated INTEGER NOT NULL)',
          );
          await d.execute('CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT)');
          await d.execute('CREATE TABLE cg(sym TEXT PRIMARY KEY, url TEXT NOT NULL)');
        },
        onUpgrade: (Database d, int o, int n) async {
          if (o < 2) {
            await d.execute('CREATE TABLE IF NOT EXISTS cg(sym TEXT PRIMARY KEY, url TEXT NOT NULL)');
          }
        },
      );
      _db = db;
      final rows = await db.query('icons');
      for (final r in rows) {
        final b = r['base'] as String;
        _updated[b] = (r['updated'] as num).toInt();
        _src[b] = (r['src'] as String?) ?? '';
        _etag[b] = (r['etag'] as String?) ?? '';
        if ((r['status'] as num).toInt() == 1) {
          final blob = r['png'];
          if (blob is Uint8List) mem[b] = blob;
        } else {
          missing.add(b);
        }
      }
      final m = await db.query('meta', where: 'k = ?', whereArgs: <Object?>['lastCheck']);
      if (m.isNotEmpty) lastCheck = int.tryParse('${m.first['v']}') ?? 0;
      final mc = await db.query('meta', where: 'k = ?', whereArgs: <Object?>['cgLast']);
      if (mc.isNotEmpty) cgLast = int.tryParse('${mc.first['v']}') ?? 0;
      for (final r in await db.query('cg')) {
        _cg[r['sym'] as String] = r['url'] as String;
      }
      notifyListeners();
    } catch (_) {}
  }

  static List<String> _urls(String b) {
    final l = b.toLowerCase();
    return <String>[
      'https://bin.bnbstatic.com/static/assets/logos/$b.png',
      'https://assets.coincap.io/assets/icons/$l@2x.png',
      'https://cdn.jsdelivr.net/gh/spothq/cryptocurrency-icons@master/128/color/$l.png',
    ];
  }

  Future<Uint8List?> _toPng(Uint8List bytes) async {
    try {
      final codec = await ui.instantiateImageCodec(bytes, targetWidth: px);
      final frame = await codec.getNextFrame();
      final bd = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      frame.image.dispose();
      codec.dispose();
      return bd?.buffer.asUint8List();
    } catch (_) {
      return null;
    }
  }

  Future<void> _save(String b, Uint8List png, String src, String etag) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.insert(
      'icons',
      <String, Object?>{'base': b, 'png': png, 'status': 1, 'src': src, 'etag': etag, 'updated': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    mem[b] = png;
    missing.remove(b);
    _updated[b] = now;
    _src[b] = src;
    _etag[b] = etag;
  }

  Future<void> _markMissing(String b) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.insert(
      'icons',
      <String, Object?>{'base': b, 'png': null, 'status': 0, 'src': '', 'etag': '', 'updated': now},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    missing.add(b);
    _updated[b] = now;
  }

  Future<void> _touch(String b) async {
    final now = DateTime.now().millisecondsSinceEpoch;
    await _db!.update('icons', <String, Object?>{'updated': now}, where: 'base = ?', whereArgs: <Object?>[b]);
    _updated[b] = now;
  }

  Future<void> _setLastCheck(int now) async {
    await _db!.insert(
      'meta',
      <String, Object?>{'k': 'lastCheck', 'v': '$now'},
      conflictAlgorithm: ConflictAlgorithm.replace,
    );
    lastCheck = now;
  }

  /// Carte symbole -> image via CoinGecko (API publique sans cle) : jusqu'a 3000 coins par ordre de capitalisation.
  /// Une page toutes les 7 s (limite gratuite), reprise apres 65 s en cas de 429. Rafraichie une fois par semaine.
  /// Retourne true si une nouvelle carte a ete chargee.
  Future<bool> _ensureCg() async {
    final now = DateTime.now().millisecondsSinceEpoch;
    if (_cg.isNotEmpty && now - cgLast < 7 * dayMs) return false;
    final map = <String, String>{};
    for (var page = 1; page <= 12; page++) {
      http.Response? r;
      for (var attempt = 0; attempt < 3; attempt++) {
        try {
          r = await _http
              .get(Uri.parse(
                  'https://api.coingecko.com/api/v3/coins/markets?vs_currency=usd&order=market_cap_desc&per_page=250&page=$page&sparkline=false'))
              .timeout(const Duration(seconds: 20));
          if (r.statusCode == 429) {
            progress.value = 'CoinGecko : limite atteinte, pause...';
            await Future<void>.delayed(const Duration(seconds: 65));
            continue;
          }
          break;
        } catch (_) {
          r = null;
          await Future<void>.delayed(const Duration(seconds: 5));
        }
      }
      if (r == null || r.statusCode != 200) break;
      final list = jsonDecode(r.body) as List<dynamic>;
      if (list.isEmpty) break;
      for (final e in list) {
        final m = e as Map<String, dynamic>;
        final s = (m['symbol'] as String?)?.toUpperCase();
        final img = m['image'] as String?;
        if (s != null && img != null && img.startsWith('http') && !map.containsKey(s)) map[s] = img;
      }
      progress.value = 'Source CoinGecko : page $page/12';
      await Future<void>.delayed(const Duration(seconds: 7));
    }
    if (map.length < 200 || _db == null) return false; // echec : on garde l'ancienne carte
    final batch = _db!.batch();
    batch.delete('cg');
    map.forEach((k, v) => batch.insert('cg', <String, Object?>{'sym': k, 'url': v}));
    batch.insert('meta', <String, Object?>{'k': 'cgLast', 'v': '$now'}, conflictAlgorithm: ConflictAlgorithm.replace);
    await batch.commit(noResult: true);
    _cg
      ..clear()
      ..addAll(map);
    cgLast = now;
    return true;
  }

  Future<bool> _fromCg(String b) async {
    final u = _cg[b];
    if (u == null) return false;
    try {
      final r = await _http.get(Uri.parse(u)).timeout(const Duration(seconds: 15));
      if (r.statusCode == 200 && r.bodyBytes.length > 64) {
        final png = await _toPng(r.bodyBytes);
        if (png != null) {
          await _save(b, png, u, r.headers['etag'] ?? '');
          return true;
        }
      }
    } catch (_) {}
    return false;
  }

  /// Retourne true si le reseau a repondu (meme par un 404), false si tout a echoue faute de reseau.
  Future<bool> _process(_Job j) async {
    final b = j.base;
    var reached = false;
    if (j.kind == 3) {
      await _fromCg(b);
      return true;
    }
    if (j.kind == 2) {
      final src = _src[b];
      if (src == null || src.isEmpty) return true;
      final et = _etag[b];
      final age = DateTime.now().millisecondsSinceEpoch - (_updated[b] ?? 0);
      if ((et == null || et.isEmpty) && age < 30 * dayMs) return true; // pas d'ETag : on ne retelecharge qu'apres 30 jours
      try {
        final r = await _http.get(Uri.parse(src), headers: <String, String>{if (et != null && et.isNotEmpty) 'If-None-Match': et})
            .timeout(const Duration(seconds: 12));
        reached = true;
        if (r.statusCode == 304) {
          await _touch(b);
        } else if (r.statusCode == 200 && r.bodyBytes.length > 64) {
          final png = await _toPng(r.bodyBytes);
          if (png != null) await _save(b, png, src, r.headers['etag'] ?? '');
        }
      } catch (_) {}
      return reached;
    }
    for (final u in _urls(b)) {
      try {
        final r = await _http.get(Uri.parse(u)).timeout(const Duration(seconds: 12));
        reached = true;
        if (r.statusCode == 200 && r.bodyBytes.length > 64) {
          final png = await _toPng(r.bodyBytes);
          if (png != null) {
            await _save(b, png, u, r.headers['etag'] ?? '');
            return true;
          }
        }
      } catch (_) {}
    }
    if (_cg.isNotEmpty && await _fromCg(b)) return true;
    if (reached) await _markMissing(b);
    return reached;
  }

  /// Synchronise la base avec la liste des jetons : telecharge les icones absentes et, une fois par jour
  /// (ou sur demande), re-essaie les manquantes et verifie les mises a jour des existantes.
  Future<void> sync(List<String> bases, {bool force = false}) async {
    if (_db == null || _syncing) return;
    _syncing = true;
    try {
      final now = DateTime.now().millisecondsSinceEpoch;
      final daily = force || now - lastCheck >= dayMs || (_cg.isEmpty && missing.isNotEmpty && now - lastCheck >= 3600000);
      final keys = <String>{for (final b in bases) iconKey(b)}.toList();
      final jobs = <_Job>[];
      for (final k in keys) {
        if (!_updated.containsKey(k)) {
          jobs.add(_Job(k, 0));
        } else if (daily) {
          jobs.add(_Job(k, missing.contains(k) ? 1 : 2));
        }
      }
      if (jobs.isEmpty) {
        if (daily && keys.isNotEmpty) await _setLastCheck(now);
        return;
      }
      final total = jobs.length;
      var next = 0;
      var done = 0;
      var netFails = 0;
      var abort = false;
      progress.value = '0/$total';
      Future<void> worker() async {
        while (!abort) {
          final i = next++;
          if (i >= total) return;
          final ok = await _process(jobs[i]);
          if (ok) {
            netFails = 0;
          } else {
            netFails++;
            if (netFails >= 15) abort = true; // pas de reseau : on reessaiera plus tard
          }
          done++;
          if (done % 5 == 0 || done == total) {
            progress.value = '$done/$total';
            notifyListeners();
          }
        }
      }

      await Future.wait(List<Future<void>>.generate(4, (_) => worker()));
      // Phase 2 : jetons toujours sans icone -> source CoinGecko (symbole -> image)
      if (!abort) {
        final still = keys.where((k) => missing.contains(k)).toList();
        if (still.isNotEmpty) {
          final fresh = await _ensureCg();
          if (_cg.isNotEmpty) {
            final targets = still.where((k) => _cg.containsKey(k)).toList();
            var d2 = 0;
            for (final k in targets) {
              await _process(_Job(k, 3));
              d2++;
              if (d2 % 5 == 0 || d2 == targets.length) {
                progress.value = 'CoinGecko : $d2/${targets.length}';
                notifyListeners();
              }
            }
            if (fresh) notifyListeners();
          }
        }
      }
      if (!abort && daily) await _setLastCheck(now);
    } catch (_) {
    } finally {
      progress.value = '';
      _syncing = false;
      notifyListeners();
    }
  }

  Future<void> forceCheck(List<String> bases) => sync(bases, force: true);
}
