import 'package:flutter/material.dart';
import '../engine.dart';
import '../pipeline.dart';
import '../theme.dart';
import 'widgets.dart';

class PipelineScreen extends StatefulWidget {
  const PipelineScreen({super.key, required this.symbol});
  final String symbol;

  @override
  State<PipelineScreen> createState() => _PipelineScreenState();
}

class _PipelineScreenState extends State<PipelineScreen> {
  PipelineResult? _res;
  Object? _err;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Chargement initial et actualisation par glissement vers le bas (RefreshIndicator).
  Future<void> _load() async {
    try {
      final r = await runPipeline(engine, widget.symbol);
      if (!mounted) return;
      setState(() {
        _res = r;
        _err = null;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _err = e);
    }
  }

  @override
  Widget build(BuildContext context) {
    final sym = widget.symbol;
    final base = sym.endsWith('USDT') ? sym.substring(0, sym.length - 4) : sym;
    final r = _res;
    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: <Widget>[
            TokenIcon(base: base, size: 30),
            const SizedBox(width: 10),
            GlowText(sym, size: 17),
            const Text('  · bureaux', style: TextStyle(fontSize: 14, color: kMuted)),
          ],
        ),
      ),
      body: (r == null && _err == null)
          ? const Center(child: CircularProgressIndicator(color: kGreen))
          : RefreshIndicator(
              color: kGreen,
              backgroundColor: kSurface,
              onRefresh: _load,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.all(10),
                children: <Widget>[
                  const Center(
                    child: Padding(
                      padding: EdgeInsets.only(bottom: 6),
                      child: Text('Tirez vers le bas pour actualiser', style: TextStyle(fontSize: 10, color: kMuted)),
                    ),
                  ),
                  if (_err != null)
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: Text('Erreur : $_err', style: const TextStyle(color: kRed)),
                    ),
                  if (r != null) ...<Widget>[
                    for (final d in r.reports) _DeskTile(d: d),
                    const SizedBox(height: 8),
                    FilledButton.icon(
                      onPressed: r.execute && r.plan != null
                          ? () {
                              final t = engine.sim.openPlan(r.plan!, engine.market, source: 'bureaux');
                              ScaffoldMessenger.of(context).showSnackBar(SnackBar(
                                content: Text(t == null
                                    ? 'Impossible : ${engine.sim.lastRefusal}'
                                    : 'Paper trade ouvert - suivi dans l onglet Simulateur'),
                              ));
                              _load();
                            }
                          : null,
                      icon: const Icon(Icons.science),
                      label: const Text('Envoyer au simulateur (paper)'),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Simulation uniquement : aucun ordre reel n est passe sur Binance. Ceci n est pas un conseil financier.',
                      textAlign: TextAlign.center,
                      style: TextStyle(fontSize: 11, color: kMuted),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _DeskTile extends StatelessWidget {
  const _DeskTile({required this.d});
  final DeskReport d;

  @override
  Widget build(BuildContext context) {
    final col = d.ok ? kGreen : kRed;
    return Card(
      color: kSurface,
      child: ExpansionTile(
        initiallyExpanded: true,
        shape: const Border(),
        collapsedShape: const Border(),
        title: Text(d.title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
        subtitle: Text(d.verdict, style: TextStyle(color: col, fontSize: 12, fontWeight: FontWeight.w600)),
        childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
        expandedCrossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final l in d.lines)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: MarkText(l, style: const TextStyle(fontSize: 12, height: 1.3)),
            ),
        ],
      ),
    );
  }
}
