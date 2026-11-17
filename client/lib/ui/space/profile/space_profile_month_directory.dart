import 'package:flutter/material.dart';

import '../../../app.dart';
import 'space_profile_controller.dart';
import 'space_profile_gateway.dart';

/// Vertical year/month directory.
///
/// Years and months are both newest-first and only months the server reported
/// as having visible entries are rendered: an empty month is skipped, never
/// inferred from the loaded pages. The selected month keeps a filled marker;
/// the month that follows the scroll position gets a lighter one.
class SpaceMonthDirectory extends StatelessWidget {
  const SpaceMonthDirectory({
    super.key,
    required this.months,
    required this.selected,
    required this.visible,
    required this.onSelect,
    required this.onLatest,
    this.atLatest = false,
    this.loading = false,
    this.error,
    this.onBack,
  });

  final List<SpaceProfileMonth> months;
  final SpaceProfileMonth? selected;
  final SpaceProfileMonth? visible;
  final void Function(SpaceProfileMonth month) onSelect;
  final VoidCallback onLatest;
  final bool atLatest;
  final bool loading;

  /// A failed directory read is shown instead of pretending the author has no
  /// visible months.
  final String? error;

  /// Optional close affordance for the phone drawer.
  final VoidCallback? onBack;

  static const Key directoryKey = Key('space-profile-directory');
  static const Key latestKey = Key('space-profile-latest');
  static const Key closeKey = Key('space-profile-directory-close');

  static Key monthKey(int year, int month) =>
      Key('space-profile-month-$year-$month');

  static Key yearKey(int year) => Key('space-profile-year-$year');

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final List<int> years = <int>[];
    for (final SpaceProfileMonth month in months) {
      if (!years.contains(month.year)) {
        years.add(month.year);
      }
    }
    return Container(
      key: directoryKey,
      color: AppColors.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(
              AppSpacing.md,
              AppSpacing.sm,
              AppSpacing.sm,
              AppSpacing.xs,
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '年月目录',
                    style: text.titleMedium?.copyWith(fontSize: 15),
                  ),
                ),
                if (onBack != null)
                  IconButton(
                    key: closeKey,
                    onPressed: onBack,
                    tooltip: '收起目录',
                    icon: const Icon(Icons.close_rounded, size: 20),
                  ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: AppSpacing.md),
            child: OutlinedButton.icon(
              key: latestKey,
              onPressed: atLatest ? null : onLatest,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size.fromHeight(40),
                alignment: Alignment.centerLeft,
              ),
              icon: const Icon(Icons.vertical_align_top_rounded, size: 18),
              label: const Text('回到最新'),
            ),
          ),
          const SizedBox(height: AppSpacing.sm),
          if (loading) const LinearProgressIndicator(minHeight: 2),
          Expanded(
            child: months.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(AppSpacing.lg),
                      child: Text(
                        error ?? (loading ? '正在读取可见月份…' : '还没有可见的月份'),
                        style: text.bodySmall?.copyWith(
                          color: error == null ? null : AppColors.danger,
                        ),
                        textAlign: TextAlign.center,
                      ),
                    ),
                  )
                : ListView(
                    padding: const EdgeInsets.only(bottom: AppSpacing.lg),
                    children: <Widget>[
                      for (final int year in years) ...<Widget>[
                        Padding(
                          key: yearKey(year),
                          padding: const EdgeInsets.fromLTRB(
                            AppSpacing.md,
                            AppSpacing.sm,
                            AppSpacing.md,
                            AppSpacing.xs,
                          ),
                          child: Text(
                            '$year 年',
                            style: text.labelLarge?.copyWith(
                              color: AppColors.inkMuted,
                              letterSpacing: 0.4,
                            ),
                          ),
                        ),
                        for (final SpaceProfileMonth month in months)
                          if (month.year == year)
                            _MonthRow(
                              month: month,
                              state: _stateFor(month),
                              onTap: () => onSelect(month),
                            ),
                      ],
                    ],
                  ),
          ),
        ],
      ),
    );
  }

  SpaceMonthState _stateFor(SpaceProfileMonth month) {
    final SpaceProfileMonth? current = selected;
    if (current != null && current == month) {
      return SpaceMonthState.selected;
    }
    final SpaceProfileMonth? seen = visible;
    if (seen != null && seen == month) {
      return SpaceMonthState.visible;
    }
    return SpaceMonthState.idle;
  }
}

class _MonthRow extends StatelessWidget {
  const _MonthRow({
    required this.month,
    required this.state,
    required this.onTap,
  });

  final SpaceProfileMonth month;
  final SpaceMonthState state;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final TextTheme text = Theme.of(context).textTheme;
    final bool selected = state == SpaceMonthState.selected;
    final bool visible = state == SpaceMonthState.visible;
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppSpacing.sm,
        vertical: 1,
      ),
      child: InkWell(
        key: SpaceMonthDirectory.monthKey(month.year, month.month),
        onTap: onTap,
        borderRadius: BorderRadius.circular(AppRadius.brand),
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: AppSpacing.sm + 4,
            vertical: AppSpacing.sm,
          ),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.accentSoft
                : visible
                ? AppColors.paper
                : Colors.transparent,
            borderRadius: BorderRadius.circular(AppRadius.brand),
            border: Border.all(
              color: selected
                  ? AppColors.accent
                  : visible
                  ? AppColors.border
                  : Colors.transparent,
              width: 1,
            ),
          ),
          child: Row(
            children: <Widget>[
              Text(
                '${month.month} 月',
                style: text.bodyMedium?.copyWith(
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppColors.accentDeep : AppColors.ink,
                ),
              ),
              const Spacer(),
              if (selected)
                const Icon(
                  Icons.radio_button_checked_rounded,
                  size: 16,
                  color: AppColors.accentDeep,
                )
              else if (visible)
                const SizedBox(
                  width: 16,
                  height: 16,
                  child: Center(
                    child: SizedBox(
                      width: 6,
                      height: 6,
                      child: DecoratedBox(
                        decoration: BoxDecoration(
                          color: AppColors.accent,
                          shape: BoxShape.circle,
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
