import 'package:flutter/material.dart';
import '../engine.dart';
import '../format.dart';
import '../models.dart';
import '../theme.dart';
import '../icon_store.dart';
import 'btc_gauges.dart';
import 'pipeline_screen.dart';
import 'quick_panel.dart';
import 'widgets.dart';

class RankingScreen extends StatelessWidget {
  const RankingScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final list = engine.ranking;
        return Scaffold(
          appBar: AppBar(
            title: Row(
              children: <Widget>[
                const Text(
                  'CRYPTO RADAR',
                  style: TextStyle(color: kGold, fontWeight: FontWeight.bold, letterSpacing: 1.5, fontSize: 16),
                ),
                const SizedBox(width: 8),
                Icon(Icons.circle, size: 10, color: engine.connected ? kGreen : kRed),
                if (engine.fallback)
                  const Padding(
                    padding: EdgeInsets.only(left: 6),
                    child: Text('HTTP', style: TextStyle(fontSize: 10, color: kMuted)),
                  ),
              ],
            ),
          ),
          body: Stack(
            fit: StackFit.expand,
            children: <Widget>[
          Column(
            children: <Widget>[
              if (engine.errorLog != null) const _ErrorBanner(),
              const _StatusBar(),
              const BtcFluxGauges(),
              Expanded(
                child: list.isEmpty
                    ? Center(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: Text(
                            engine.favoritesOnly ? 'Aucun favori. Appui long sur un jeton pour ajouter une etoile.' : engine.status,
                            textAlign: TextAlign.center,
                            style: const TextStyle(color: kMuted),
                          ),
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(8, 4, 8, 90),
                        itemCount: list.length,
                        itemBuilder: (BuildContext context, int i) => _TokenCard(t: list[i]),
                      ),
              ),
            ],
          ),
              Positioned(
                left: 14,
                bottom: 14,
                child: FloatingActionButton.small(
                  heroTag: null,
                  tooltip: 'Acces rapide',
                  onPressed: () => showQuickPanel(context),
                  backgroundColor: kSurface2,
                  foregroundColor: kGold,
                  child: const Icon(Icons.bolt),
                ),
              ),
            ],
          ),
          floatingActionButton: FloatingActionButton.extended(
            onPressed: () => showScanSheet(context),
            icon: const Icon(Icons.radar),
            label: const Text('SCAN'),
            backgroundColor: kGold,
            foregroundColor: Colors.black,
          ),
        );
      },
    );
  }
}

class _ErrorBanner extends StatelessWidget {
  const _ErrorBanner();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) => _content(context),
    );
  }

  Widget _content(BuildContext context) {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 160),
      margin: const EdgeInsets.fromLTRB(8, 6, 8, 0),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: kRed.withOpacity(0.15),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: kRed),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Expanded(
                child: Text('Journal d erreur (copiable)', style: TextStyle(color: kRed, fontWeight: FontWeight.bold, fontSize: 12)),
              ),
              InkWell(onTap: engine.clearError, child: const Icon(Icons.close, size: 18)),
            ],
          ),
          Expanded(
            child: SingleChildScrollView(
              child: SelectableText(engine.errorLog ?? '', style: const TextStyle(fontSize: 10)),
            ),
          ),
        ],
      ),
    );
  }
}

class _TokenCard extends StatelessWidget {
  const _TokenCard({required this.t});
  final TokenData t;

  @override
  Widget build(BuildContext context) {
    final up = t.change24 >= 0;
    final col = up ? kGreen : kRed;
    final hot = t.score >= engine.sens.alertScore;
    final fav = engine.favorites.contains(t.symbol);
    return InkWell(
      borderRadius: BorderRadius.circular(10),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (BuildContext _) => PipelineScreen(symbol: t.symbol)),
      ),
      onLongPress: () => engine.toggleFavorite(t.symbol),
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 3),
        padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        decoration: BoxDecoration(
          color: kSurface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: hot ? kRed.withOpacity(0.7) : kSurface2),
        ),
        child: Column(
          children: <Widget>[
            Row(
              children: <Widget>[
                SizedBox(
                  width: 28,
                  child: Text('#${t.rank}', style: const TextStyle(color: kMuted, fontSize: 11)),
                ),
                TokenIcon(base: t.base, size: 34),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          GlowText(t.base, size: 17, glow: up ? kNeonGreen : kNeonRed),
                          if (fav) const Padding(
                            padding: EdgeInsets.only(left: 4),
                            child: Icon(Icons.star, size: 14, color: kGold),
                          ),
                        ],
                      ),
                      Text(
                        'Vol ${fmtVol(t.quoteVol24)} · ${t.speed} · ↑${t.upEvents} ↓${t.downEvents}',
                        style: const TextStyle(fontSize: 10, color: kMuted),
                      ),
                    ],
                  ),
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(fmtPrice(t.price), style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
                    Text(fmtPct2(t.change24), style: TextStyle(color: col, fontSize: 12)),
                  ],
                ),
                const SizedBox(width: 10),
                ScoreBadge(score: t.score, direction: t.direction, hot: hot),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: <Widget>[
                for (final p in kPeriods)
                  Expanded(
                    child: VolumeCandle(
                      label: periodLabel(p),
                      value: (engine.showPrice ? t.priceVar[p] : t.volVar[p]) ?? 0.0,
                      ready: (engine.showPrice ? t.priceVar : t.volVar).containsKey(p) || t.klinesLoaded,
                      missing: t.klinesLoaded && !(engine.showPrice ? t.priceVar : t.volVar).containsKey(p),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

void showScanSheet(BuildContext context) {
  showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: kSurface,
    builder: (BuildContext ctx) {
      return ListenableBuilder(
        listenable: engine,
        builder: (BuildContext ctx, Widget? _) {
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  const Text('SCAN · parametres pre-configures',
                      style: TextStyle(color: kGold, fontWeight: FontWeight.bold, fontSize: 15)),
                  const SizedBox(height: 8),
                  const _BtcScanCard(),
                  const SizedBox(height: 8),
                  for (var i = 0; i < kPresets.length; i++)
                    ListTile(
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      leading: Icon(
                        engine.presetIndex == i ? Icons.radio_button_checked : Icons.radio_button_off,
                        color: engine.presetIndex == i ? kGold : kMuted,
                      ),
                      title: Text(kPresets[i].name),
                      subtitle: Text(kPresets[i].desc, style: const TextStyle(fontSize: 11)),
                      onTap: () => engine.applyPreset(i),
                    ),
                  const Divider(),
                  const Text('Sensibilite du classement', style: TextStyle(fontSize: 12, color: kMuted)),
                  Wrap(
                    spacing: 6,
                    children: <Widget>[
                      for (final s in Sensitivity.values)
                        ChoiceChip(
                          label: Text(s.label),
                          selected: engine.sens == s,
                          onSelected: (bool _) => engine.setSensitivity(s),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('Nombre de jetons scannes', style: TextStyle(fontSize: 12, color: kMuted)),
                  Wrap(
                    spacing: 6,
                    children: <Widget>[
                      for (final n in const <int>[30, 50, 100, 150, 200])
                        ChoiceChip(
                          label: Text('Top $n'),
                          selected: engine.topN == n,
                          onSelected: (bool _) => engine.setTopN(n),
                        ),
                    ],
                  ),
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('Favoris uniquement'),
                    subtitle: Text('${engine.favorites.length} jeton(s) en etoile (appui long dans le classement)',
                        style: const TextStyle(fontSize: 11)),
                    value: engine.favoritesOnly,
                    onChanged: engine.setFavoritesOnly,
                  ),
                  Text(
                    'Alerte quand ≥ ${engine.sens.minEvents} mouvements de ${engine.sens.step}% dans le meme sens '
                    'et score ≥ ${engine.sens.alertScore.round()}.',
                    style: const TextStyle(fontSize: 11, color: kMuted),
                  ),
                ],
              ),
            ),
          );
        },
      );
    },
  );
}

class _BtcScanCard extends StatelessWidget {
  const _BtcScanCard();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final tr = engine.btcTrend;
        final col = tr == Trend.bull ? kGreen : (tr == Trend.bear ? kRed : kMuted);
        final mode = tr == Trend.bull
            ? 'HAUSSIER (contexte favorable aux longs)'
            : (tr == Trend.bear ? 'BAISSIER (contexte favorable aux shorts)' : 'en attente du flux...');
        return Container(
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: col.withOpacity(0.12),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: col.withOpacity(0.5)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(Icons.currency_bitcoin, color: col),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text('FLUX BTC $mode',
                        style: TextStyle(color: col, fontWeight: FontWeight.bold, fontSize: 12)),
                  ),
                  IconButton(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.refresh),
                    onPressed: engine.refreshBtcNow,
                  ),
                ],
              ),
              const SizedBox(height: 4),
              SegmentedButton<BtcMode>(
                showSelectedIcon: false,
                style: const ButtonStyle(visualDensity: VisualDensity.compact),
                segments: const <ButtonSegment<BtcMode>>[
                  ButtonSegment<BtcMode>(value: BtcMode.short, label: Text('COURT TERME · EMA 1h', style: TextStyle(fontSize: 10))),
                  ButtonSegment<BtcMode>(value: BtcMode.long, label: Text('LONG TERME · EMA 4h', style: TextStyle(fontSize: 10))),
                ],
                selected: <BtcMode>{engine.btcMode},
                onSelectionChanged: (Set<BtcMode> v) => engine.setBtcMode(v.first),
              ),
              Text(engine.btcInfo, style: const TextStyle(fontSize: 10, color: kMuted)),
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  'Les notifications sont reservees au paper trading (ouverture et cloture). Les alertes du scan restent visibles dans l onglet Alertes.',
                  style: TextStyle(fontSize: 10, color: kMuted),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _StatusBar extends StatelessWidget {
  const _StatusBar();

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: engine,
      builder: (BuildContext context, Widget? _) {
        final bad = engine.lastNetErr.isNotEmpty && !engine.connected;
        return Padding(
          padding: const EdgeInsets.fromLTRB(10, 4, 10, 0),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(engine.netStatus, style: const TextStyle(fontSize: 10, color: kMuted)),
              ValueListenableBuilder<String>(
                valueListenable: IconStore.I.progress,
                builder: (BuildContext c, String v, Widget? _) => v.isEmpty
                    ? const SizedBox.shrink()
                    : Text('Telechargement des icones : $v', style: const TextStyle(fontSize: 9, color: kGold)),
              ),
              if (bad)
                Text(engine.lastNetErr, style: const TextStyle(fontSize: 9, color: kRed)),
            ],
          ),
        );
      },
    );
  }
}
