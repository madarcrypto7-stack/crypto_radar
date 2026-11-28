import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import '../format.dart';
import '../icon_store.dart';
import '../theme.dart';

/// Petite bougie verte/rouge dont la taille suit la variation de volume (dynamique, animee).
class VolumeCandle extends StatelessWidget {
  const VolumeCandle({super.key, required this.label, required this.value, required this.ready, this.missing = false});
  final String label;
  final double value;
  final bool ready;
  final bool missing;

  @override
  Widget build(BuildContext context) {
    final col = value >= 0 ? kGreen : kRed;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Text(label, style: const TextStyle(fontSize: 9, color: kMuted)),
        TweenAnimationBuilder<double>(
          tween: Tween<double>(end: ready ? value : 0.0),
          duration: const Duration(milliseconds: 500),
          builder: (BuildContext context, double v, Widget? _) {
            return SizedBox(
              height: 36,
              width: 14,
              child: CustomPaint(painter: _CandlePainter(v)),
            );
          },
        ),
        Text(
          missing ? 'n/d' : (ready ? fmtPct(value) : '...'),
          style: TextStyle(
            fontSize: 9,
            fontWeight: FontWeight.w600,
            color: (ready && !missing) ? col : kMuted,
          ),
        ),
      ],
    );
  }
}

class _CandlePainter extends CustomPainter {
  _CandlePainter(this.v);
  final double v;

  @override
  void paint(Canvas canvas, Size size) {
    final mid = size.height / 2;
    final base = Paint()
      ..color = kSurface2
      ..strokeWidth = 1;
    canvas.drawLine(Offset(0, mid), Offset(size.width, mid), base);
    final mag = math.min(1.0, v.abs() / 100.0);
    final body = math.max(2.0, mag * (mid - 3));
    final color = v >= 0 ? kGreen : kRed;
    final top = v >= 0 ? mid - body : mid;
    final wick = Paint()
      ..color = color
      ..strokeWidth = 1;
    final cx = size.width / 2;
    canvas.drawLine(Offset(cx, math.max(0.0, top - 3)), Offset(cx, math.min(size.height, top + body + 3)), wick);
    canvas.drawRRect(
      RRect.fromRectAndRadius(Rect.fromLTWH(2, top, size.width - 4, body), const Radius.circular(1.5)),
      Paint()..color = color,
    );
  }

  @override
  bool shouldRepaint(covariant _CandlePainter old) => old.v != v;
}

class ScoreBadge extends StatelessWidget {
  const ScoreBadge({super.key, required this.score, required this.direction, required this.hot});
  final double score;
  final String direction;
  final bool hot;

  @override
  Widget build(BuildContext context) {
    final col = hot ? kRed : (score >= 30 ? kGold : kMuted);
    final arrow = direction == 'up' ? '↑' : (direction == 'down' ? '↓' : '·');
    return Container(
      width: 46,
      padding: const EdgeInsets.symmetric(vertical: 4),
      decoration: BoxDecoration(
        color: col.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: col.withOpacity(0.6)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text('${score.round()}', style: TextStyle(color: col, fontWeight: FontWeight.bold, fontSize: 15)),
          Text(arrow, style: TextStyle(color: col, fontSize: 11)),
        ],
      ),
    );
  }
}

/// Nom de jeton lumineux : halo flou colore + texte degrade blanc -> couleur.
class GlowText extends StatelessWidget {
  const GlowText(this.text, {super.key, this.size = 16, this.glow = kNeonGreen});
  final String text;
  final double size;
  final Color glow;

  @override
  Widget build(BuildContext context) {
    final base = TextStyle(fontSize: size, fontWeight: FontWeight.w800, letterSpacing: 0.8);
    return Stack(
      children: <Widget>[
        Text(
          text,
          style: base.copyWith(
            foreground: Paint()
              ..style = PaintingStyle.stroke
              ..strokeWidth = 3
              ..color = glow.withOpacity(0.6)
              ..maskFilter = const ui.MaskFilter.blur(ui.BlurStyle.normal, 5),
          ),
        ),
        ShaderMask(
          shaderCallback: (Rect r) => LinearGradient(
            colors: <Color>[Colors.white, glow],
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
          ).createShader(r),
          child: Text(text, style: base.copyWith(color: Colors.white)),
        ),
      ],
    );
  }
}

/// Icone du jeton : lue depuis la base locale (aucune requete reseau a l'affichage).
/// Repli : pastille coloree avec les deux premieres lettres.
class TokenIcon extends StatelessWidget {
  const TokenIcon({super.key, required this.base, this.size = 32});
  final String base;
  final double size;

  Widget _fallback(String name) {
    var h = 0;
    for (final u in name.codeUnits) {
      h = (h * 31 + u) & 0x7fffffff;
    }
    final c1 = HSLColor.fromAHSL(1, (h % 360).toDouble(), 0.60, 0.42).toColor();
    final c2 = HSLColor.fromAHSL(1, ((h + 40) % 360).toDouble(), 0.65, 0.28).toColor();
    final letters = name.length >= 2 ? name.substring(0, 2) : name;
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        gradient: LinearGradient(colors: <Color>[c1, c2], begin: Alignment.topLeft, end: Alignment.bottomRight),
      ),
      child: Text(
        letters,
        style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: size * 0.36),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final key = iconKey(base);
    final bytes = IconStore.I.mem[key];
    if (bytes == null) return _fallback(key.isEmpty ? '?' : key);
    return SizedBox(
      width: size,
      height: size,
      child: ClipOval(
        child: Image.memory(
          bytes,
          width: size,
          height: size,
          fit: BoxFit.cover,
          gaplessPlayback: true,
          filterQuality: FilterQuality.medium,
        ),
      ),
    );
  }
}

/// Texte dont les marques ✔ (rempli) et ✘ (non rempli) sont en vert vif / rouge vif, plus grosses et en gras.
class MarkText extends StatelessWidget {
  const MarkText(this.text, {super.key, this.style});
  final String text;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    final base = style ?? DefaultTextStyle.of(context).style;
    final size = (base.fontSize ?? 12) * 1.2;
    final spans = <InlineSpan>[];
    final buf = StringBuffer();
    void flush() {
      if (buf.isNotEmpty) {
        spans.add(TextSpan(text: buf.toString()));
        buf.clear();
      }
    }

    for (final r in text.runes) {
      final ch = String.fromCharCode(r);
      if (ch == '✔' || ch == '✘') {
        flush();
        spans.add(TextSpan(
          text: ch,
          style: TextStyle(
            color: ch == '✔' ? kOk : kNo,
            fontWeight: FontWeight.w900,
            fontSize: size,
            shadows: <Shadow>[Shadow(color: (ch == '✔' ? kOk : kNo).withOpacity(0.7), blurRadius: 4)],
          ),
        ));
      } else {
        buf.write(ch);
      }
    }
    flush();
    return Text.rich(TextSpan(style: base, children: spans));
  }
}
