import 'package:flutter/material.dart';

import 'app.dart';

/// A deliberately tiny end-to-end surface for the delivery pipeline.
///
/// It owns one piece of local UI state only: whether the smoke check has been
/// run. There is no network, storage or authentication dependency here.
class PipelineSmokePage extends StatefulWidget {
  const PipelineSmokePage({super.key});

  static const String title = 'Pipeline Smoke';
  static const String readyLabel = 'Ready';
  static const String completeLabel = 'Smoke check complete';
  static const String runLabel = 'Run smoke check';
  static const Key runButtonKey = Key('run-smoke-check');

  @override
  State<PipelineSmokePage> createState() => _PipelineSmokePageState();
}

class _PipelineSmokePageState extends State<PipelineSmokePage> {
  bool _completed = false;

  String get _statusLabel => _completed
      ? PipelineSmokePage.completeLabel
      : PipelineSmokePage.readyLabel;

  String get _statusHint => _completed
      ? 'The client rendered and responded to the action.'
      : 'Waiting for the first check.';

  void _runSmokeCheck() {
    setState(() {
      _completed = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Scaffold(
      body: SafeArea(
        child: Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.symmetric(
              horizontal: AppSpacing.lg,
              vertical: AppSpacing.xl,
            ),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const _BrandRow(),
                  const SizedBox(height: AppSpacing.xxl),
                  Text(
                    'PIPELINE SMOKE CHECK',
                    style: text.labelSmall?.copyWith(color: AppColors.accent),
                  ),
                  const SizedBox(height: AppSpacing.sm),
                  Semantics(
                    header: true,
                    child: Text(
                      PipelineSmokePage.title,
                      style: text.headlineLarge,
                    ),
                  ),
                  const SizedBox(height: AppSpacing.sm + AppSpacing.xs),
                  Text(
                    'The shortest end-to-end check: the app boots, '
                    'renders a status, and responds to one action.',
                    style: text.bodyLarge,
                  ),
                  const SizedBox(height: AppSpacing.xl),
                  _StatusCard(
                    completed: _completed,
                    label: _statusLabel,
                    hint: _statusHint,
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      key: PipelineSmokePage.runButtonKey,
                      autofocus: true,
                      onPressed: _runSmokeCheck,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: <Widget>[
                          ExcludeSemantics(
                            child: Icon(
                              _completed
                                  ? Icons.check_rounded
                                  : Icons.play_arrow_rounded,
                              size: 20,
                            ),
                          ),
                          const SizedBox(width: AppSpacing.sm + 2),
                          const Flexible(
                            child: Text(
                              PipelineSmokePage.runLabel,
                              textAlign: TextAlign.center,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                  const SizedBox(height: AppSpacing.lg),
                  Text(
                    'Local UI state · no network required',
                    textAlign: TextAlign.center,
                    style: text.bodySmall,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _BrandRow extends StatelessWidget {
  const _BrandRow();

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 44,
          height: 44,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: AppColors.accent,
            borderRadius: BorderRadius.circular(AppRadius.brand),
          ),
          child: const Text(
            'BB',
            style: TextStyle(
              color: AppColors.surface,
              fontSize: 15,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.6,
            ),
          ),
        ),
        const SizedBox(width: AppSpacing.md - AppSpacing.xs),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              'BB',
              style: text.labelSmall?.copyWith(
                color: AppColors.ink,
                letterSpacing: 1.8,
              ),
            ),
            const SizedBox(height: 2),
            Text('SOCIAL PLATFORM', style: text.labelSmall),
          ],
        ),
      ],
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({
    required this.completed,
    required this.label,
    required this.hint,
  });

  final bool completed;
  final String label;
  final String hint;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;

    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Status: $label',
      child: ExcludeSemantics(
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          padding: const EdgeInsets.all(AppSpacing.lg),
          decoration: BoxDecoration(
            color: completed ? AppColors.successSurface : AppColors.surface,
            borderRadius: BorderRadius.circular(AppRadius.card),
            border: Border.all(
              color: completed ? AppColors.successBorder : AppColors.border,
            ),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              AnimatedContainer(
                duration: const Duration(milliseconds: 220),
                width: 40,
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: completed
                      ? AppColors.success.withValues(alpha: 0.12)
                      : AppColors.paper,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  completed
                      ? Icons.check_rounded
                      : Icons.radio_button_unchecked_rounded,
                  size: 20,
                  color: completed ? AppColors.success : AppColors.inkMuted,
                ),
              ),
              const SizedBox(width: AppSpacing.md),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text('STATUS', style: text.labelSmall),
                    const SizedBox(height: AppSpacing.sm + 2),
                    AnimatedSwitcher(
                      duration: const Duration(milliseconds: 180),
                      child: Text(
                        label,
                        key: ValueKey<String>(label),
                        style: text.titleLarge?.copyWith(
                          color: completed ? AppColors.success : AppColors.ink,
                        ),
                      ),
                    ),
                    const SizedBox(height: AppSpacing.sm),
                    Text(hint, style: text.bodySmall),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
