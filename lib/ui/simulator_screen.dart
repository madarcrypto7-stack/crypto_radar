import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../engine.dart';
import '../format.dart';
import '../journal.dart';
import '../native_bridge.dart';
import '../simulator.dart';
import '../theme.dart';
import 'chart_screen.dart';
import 'widgets.dart';

class SimulatorScreen extends StatelessWidget {
  const SimulatorScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final s = engine.sim;
        final eq = s.equity();
        final pnl = eq - Simulator.startBalance;
        final col = pnl >= 0 ? kGreen : kRed;
        return Scaffold(
          appBar: AppBar(
            title: const Text('SIMULATEUR (PAPER)'),
            actions: <Widget>[
              IconButton(
                icon: const Icon(Icons.restart_alt),
                onPressed: () async {
                  final ok = await showDialog<bool>(
                    context: context,
                    builder: (BuildContext c) => AlertDialog(
                      title: const Text('Reinitialiser ?'),
                      content: const Text('Le capital virtuel revient a 10 000 USDT et l historique est efface.'),
                      actions: <Widget>[
                        TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Annuler')),
                        TextButton(onPressed: () => Navigator.pop(c, true), child: const Text('Reinitialiser')),
                      ],
                    ),
                  );
                  if (ok == true) engine.resetSim();
                },
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.all(10),
            children: <Widget>[
              Card(
                color: kSurface,
                child: Padding(
                  padding: const EdgeInsets.all(14),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const Text('Capital virtuel (equity)', style: TextStyle(color: kMuted, fontSize: 12)),
                      Text('${eq.toStringAsFixed(2)} USDT',
                          style: const TextStyle(fontSize: 26, fontWeight: FontWeight.bold)),
                      Text('${fmtUsd(pnl)} USDT depuis le depart',
                          style: TextStyle(color: col, fontWeight: FontWeight.w600)),
                      Text('Solde realise : ${s.balance.toStringAsFixed(2)} · positions ouvertes : ${s.open.length}/20',
                          style: const TextStyle(color: kMuted, fontSize: 11)),
                    ],
                  ),
                ),
              ),
              const _JournalCard(),
              SwitchListTile(
                title: const Text('Trading automatique sur alerte'),
                subtitle: Text(
                  engine.sim.lastAutoMsg.isEmpty
                      ? 'Ouvre un paper trade quand une alerte est alignee avec le flux BTC (long si haussier, short si baissier)'
                      : 'Dernier : ${engine.sim.lastAutoMsg}',
                  style: const TextStyle(fontSize: 11),
                ),
                value: engine.autoTrade,
                onChanged: engine.setAutoTrade,
              ),
              if (s.open.isNotEmpty) const _Section('Positions ouvertes'),
              for (final t in s.open) _OpenCard(t: t),
              if (s.history.isNotEmpty) const _Section('Historique'),
              for (final t in s.history.take(40)) _HistoryTile(t: t),
              if (s.open.isEmpty && s.history.isEmpty)
                const Padding(
                  padding: EdgeInsets.all(24),
                  child: Text(
                    'Aucune position. Ouvrez un jeton dans le classement, lancez les bureaux puis envoyez le plan ici.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: kMuted),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _Section extends StatelessWidget {
  const _Section(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Text(text, style: const TextStyle(color: kGold, fontWeight: FontWeight.bold)),
      );
}

class _OpenCard extends StatelessWidget {
  const _OpenCard({required this.t});
  final PaperTrade t;

  @override
  Widget build(BuildContext context) {
    final p = engine.tokens[t.symbol]?.price ?? t.entry;
    final pnl = t.unrealized(p) + t.realized;
    final col = pnl >= 0 ? kGreen : kRed;
    return Card(
      color: kSurface,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: () => Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (BuildContext _) => ChartScreen(trade: t)),
        ),
        child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                TokenIcon(base: t.symbol.endsWith('USDT') ? t.symbol.substring(0, t.symbol.length - 4) : t.symbol, size: 30),
                const SizedBox(width: 8),
                GlowText(t.symbol, size: 15, glow: t.long ? kNeonGreen : kNeonRed),
                const SizedBox(width: 8),
                Chip(
                  label: Text('${t.long ? 'LONG' : 'SHORT'} x${t.leverage.toStringAsFixed(0)} ${t.futures ? 'FUT' : 'SPOT'}',
                      style: const TextStyle(fontSize: 10)),
                  visualDensity: VisualDensity.compact,
                ),
                const Spacer(),
                Text('${fmtUsd(pnl)} USDT', style: TextStyle(color: col, fontWeight: FontWeight.bold)),
              ],
            ),
            Text(
              'Entree ${fmtPrice(t.entry)} · SL ${fmtPrice(t.sl)}${t.tp1Hit ? ' (BE)' : ''}\n'
              'TP1 ${fmtPrice(t.tp1)}${t.tp1Hit ? ' ✔' : ''} · TP2 ${fmtPrice(t.tp2)} · prix ${fmtPrice(p)}',
              style: const TextStyle(fontSize: 11, color: kMuted),
            ),
            Row(
              children: <Widget>[
                const Icon(Icons.candlestick_chart, size: 16, color: kMuted),
                const SizedBox(width: 4),
                const Text('Toucher pour voir le graphique', style: TextStyle(fontSize: 10, color: kMuted)),
                const Spacer(),
                TextButton(
                  onPressed: () => engine.sim.closeManual(t),
                  child: const Text('FERMER'),
                ),
              ],
            ),
          ],
        ),
      ),
      ),
    );
  }
}

class _HistoryTile extends StatelessWidget {
  const _HistoryTile({required this.t});
  final PaperTrade t;

  @override
  Widget build(BuildContext context) {
    final col = t.realized >= 0 ? kGreen : kRed;
    final label = switch (t.status) {
      'tp' => 'TP2',
      'sl' => 'Stop loss',
      'be' => 'Break-even',
      _ => 'Manuel',
    };
    return ListTile(
      dense: true,
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (BuildContext _) => ChartScreen(trade: t)),
      ),
      leading: Icon(t.long ? Icons.north_east : Icons.south_east, color: col, size: 18),
      title: Text('${t.symbol} · ${t.long ? 'LONG' : 'SHORT'}'),
      subtitle: Text('$label · ${fmtTime(t.closedAt ?? t.openedAt)}', style: const TextStyle(fontSize: 11)),
      trailing: Text('${fmtUsd(t.realized)} USDT', style: TextStyle(color: col, fontWeight: FontWeight.w600)),
    );
  }
}

class _JournalCard extends StatelessWidget {
  const _JournalCard();

  String _stamp() {
    final d = DateTime.now();
    return '${d.year}${two(d.month)}${two(d.day)}_${two(d.hour)}${two(d.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final sim = engine.sim;
        final st = journalStats(sim);
        final empty = sim.open.isEmpty && sim.history.isEmpty;
        final col = st.totalPnl >= 0 ? kGreen : kRed;
        return Card(
          color: kSurface,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const Text('JOURNAL DE TRADING', style: TextStyle(color: kGold, fontWeight: FontWeight.bold)),
                const SizedBox(height: 6),
                if (empty)
                  const Text('Aucun trade pour le moment.', style: TextStyle(color: kMuted, fontSize: 12))
                else ...<Widget>[
                  Text(
                    '${st.closed} trade(s) clos · ${st.open} ouvert(s) · gagnants ${st.winRate.toStringAsFixed(0)} %',
                    style: const TextStyle(fontSize: 12),
                  ),
                  Text('PnL realise : ${fmtUsd(st.totalPnl)} USDT',
                      style: TextStyle(fontSize: 12, color: col, fontWeight: FontWeight.w600)),
                  Text(
                    'Facteur de profit ${st.profitFactor.toStringAsFixed(2)} · R moyen ${st.avgR.toStringAsFixed(2)} · '
                    'meilleur ${fmtUsd(st.best)} · pire ${fmtUsd(st.worst)}',
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                ],
                const SizedBox(height: 8),
                Row(
                  children: <Widget>[
                    Expanded(
                      child: FilledButton.icon(
                        onPressed: empty
                            ? null
                            : () async {
                                final messenger = ScaffoldMessenger.of(context);
                                final csv = buildJournalCsv(sim, (String s) => engine.tokens[s]?.price);
                                final name = 'crypto_radar_journal_${_stamp()}.csv';
                                final path = await NativeBridge.saveFile(name, 'text/csv', '\uFEFF$csv');
                                messenger.showSnackBar(SnackBar(
                                  content: Text(path == null
                                      ? 'Echec de l enregistrement du journal'
                                      : 'Journal enregistre : $path'),
                                ));
                              },
                        icon: const Icon(Icons.download),
                        label: const Text('Telecharger (CSV)'),
                      ),
                    ),
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: empty
                          ? null
                          : () async {
                              final messenger = ScaffoldMessenger.of(context);
                              final csv = buildJournalCsv(sim, (String s) => engine.tokens[s]?.price);
                              await Clipboard.setData(ClipboardData(text: csv));
                              messenger.showSnackBar(const SnackBar(content: Text('Journal copie dans le presse-papiers')));
                            },
                      icon: const Icon(Icons.copy, size: 16),
                      label: const Text('Copier'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}
