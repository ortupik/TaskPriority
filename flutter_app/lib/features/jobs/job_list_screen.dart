import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/sync/sync_engine.dart';
import '../../core/storage/app_database.dart';
import 'job_repository.dart';

part 'job_list_screen.g.dart';

// ── Providers ─────────────────────────────────────────────────────────────

@riverpod
class JobListFilter extends _$JobListFilter {
  @override
  JobListFilterState build() => const JobListFilterState();

  void setSearch(String q) => state = state.copyWith(search: q);
  void setStatus(String? s) => state = state.copyWith(status: s, clearStatus: s == null);
  void clearAll() => state = const JobListFilterState();
}

class JobListFilterState {
  final String search;
  final String? status;

  const JobListFilterState({this.search = '', this.status});

  JobListFilterState copyWith({String? search, String? status, bool clearStatus = false}) =>
      JobListFilterState(
        search: search ?? this.search,
        status: clearStatus ? null : (status ?? this.status),
      );
}

@riverpod
Future<List<JobModel>> filteredJobs(Ref ref) async {
  final repo = ref.watch(jobRepositoryProvider);
  final filter = ref.watch(jobListFilterProvider);
  final all = await repo.getLocalJobs();

  return all.where((j) {
    final matchSearch = filter.search.isEmpty ||
        j.customerName.toLowerCase().contains(filter.search.toLowerCase()) ||
        j.customerAddress.toLowerCase().contains(filter.search.toLowerCase()) ||
        j.jobNumber.toLowerCase().contains(filter.search.toLowerCase()) ||
        j.title.toLowerCase().contains(filter.search.toLowerCase());

    final matchStatus = filter.status == null || j.status == filter.status;

    return matchSearch && matchStatus;
  }).toList()
    ..sort((a, b) {
      // Overdue first, then by scheduled start
      if (a.isOverdue && !b.isOverdue) return -1;
      if (!a.isOverdue && b.isOverdue) return 1;
      return a.scheduledStart.compareTo(b.scheduledStart);
    });
}

// ── Screen ────────────────────────────────────────────────────────────────

class JobListScreen extends ConsumerStatefulWidget {
  const JobListScreen({super.key});

  @override
  ConsumerState<JobListScreen> createState() => _JobListScreenState();
}

class _JobListScreenState extends ConsumerState<JobListScreen> {
  final _searchCtrl = TextEditingController();
  bool _isRefreshing = false;

  @override
  void initState() {
    super.initState();
    // Initial sync on mount
    WidgetsBinding.instance.addPostFrameCallback((_) => _doRefresh());
  }

  @override
  void dispose() {
    _searchCtrl.dispose();
    super.dispose();
  }

  Future<void> _doRefresh() async {
    if (_isRefreshing) return;
    setState(() => _isRefreshing = true);
    try {
      final repo = ref.read(jobRepositoryProvider);
      await repo.syncFromServer();
      ref.invalidate(filteredJobsProvider);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Sync failed: ${e.toString()}'),
            action: SnackBarAction(label: 'Retry', onPressed: _doRefresh),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isRefreshing = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final syncState = ref.watch(syncNotifierProvider);
    final filter = ref.watch(jobListFilterProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('My Jobs'),
        centerTitle: false,
        actions: [
          // Pending sync badge
          if (syncState.pendingCount > 0)
            Padding(
              padding: const EdgeInsets.only(right: 4),
              child: _SyncBadge(
                count: syncState.pendingCount,
                isSyncing: syncState.status == SyncStatus.syncing,
                onTap: () => ref.read(syncNotifierProvider.notifier).flushQueue(),
              ),
            ),
          IconButton(
            icon: const Icon(Icons.person_outline),
            onPressed: () => Navigator.pushNamed(context, '/profile'),
          ),
        ],
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(56),
          child: _SearchBar(
            controller: _searchCtrl,
            onChanged: (q) {
              ref.read(jobListFilterProvider.notifier).setSearch(q);
              ref.invalidate(filteredJobsProvider);
            },
          ),
        ),
      ),
      body: Column(
        children: [
          _StatusFilterRow(
            selected: filter.status,
            onSelected: (s) {
              ref.read(jobListFilterProvider.notifier).setStatus(s);
              ref.invalidate(filteredJobsProvider);
            },
          ),
          Expanded(
            child: RefreshIndicator(
              onRefresh: _doRefresh,
              child: _JobListBody(isRefreshing: _isRefreshing),
            ),
          ),
        ],
      ),
    );
  }
}

class _SearchBar extends StatelessWidget {
  final TextEditingController controller;
  final ValueChanged<String> onChanged;

  const _SearchBar({required this.controller, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      child: TextField(
        controller: controller,
        onChanged: onChanged,
        decoration: InputDecoration(
          hintText: 'Search by customer, address, or job ID…',
          prefixIcon: const Icon(Icons.search, size: 20),
          suffixIcon: controller.text.isNotEmpty
              ? IconButton(
                  icon: const Icon(Icons.clear, size: 18),
                  onPressed: () {
                    controller.clear();
                    onChanged('');
                  },
                )
              : null,
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(10)),
          filled: true,
          fillColor: Theme.of(context).colorScheme.surfaceContainerHighest,
        ),
      ),
    );
  }
}

class _StatusFilterRow extends StatelessWidget {
  final String? selected;
  final ValueChanged<String?> onSelected;

  const _StatusFilterRow({required this.selected, required this.onSelected});

  static const _filters = [
    (null, 'All'),
    ('pending', 'Pending'),
    ('in_progress', 'In Progress'),
    ('completed', 'Completed'),
    ('on_hold', 'On Hold'),
  ];

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 44,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: _filters.length,
        separatorBuilder: (_, __) => const SizedBox(width: 8),
        itemBuilder: (context, i) {
          final (value, label) = _filters[i];
          final isSelected = selected == value;
          return FilterChip(
            label: Text(label, style: TextStyle(fontSize: 13,
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal)),
            selected: isSelected,
            onSelected: (_) => onSelected(isSelected ? null : value),
            showCheckmark: false,
            materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
          );
        },
      ),
    );
  }
}

class _JobListBody extends ConsumerWidget {
  final bool isRefreshing;
  const _JobListBody({required this.isRefreshing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final jobsAsync = ref.watch(filteredJobsProvider);

    return jobsAsync.when(
      loading: () => const _JobListSkeleton(),
      error: (e, _) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.cloud_off, size: 48, color: Colors.grey),
            const SizedBox(height: 12),
            Text('Failed to load jobs', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            Text(e.toString(), style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
      data: (jobs) {
        if (jobs.isEmpty) {
          return Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.assignment_outlined, size: 56,
                    color: Theme.of(context).colorScheme.outline),
                const SizedBox(height: 12),
                Text('No jobs found',
                    style: Theme.of(context).textTheme.titleMedium),
              ],
            ),
          );
        }

        // ListView.builder is O(1) memory regardless of item count — 60fps at 500+
        return ListView.builder(
          itemCount: jobs.length,
          // RepaintBoundary prevents list from repainting outside the viewport
          itemBuilder: (context, i) => RepaintBoundary(
            child: _JobCard(job: jobs[i]),
          ),
        );
      },
    );
  }
}

// ── Job card — const-constructible for maximum widget reuse ──────────────

class _JobCard extends StatelessWidget {
  final JobModel job;
  const _JobCard({required this.job});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final tt = Theme.of(context).textTheme;
    final timeStr = DateFormat('E, MMM d · h:mm a').format(job.scheduledStart.toLocal());

    return InkWell(
      onTap: () => Navigator.pushNamed(context, '/jobs/${job.id}'),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        decoration: BoxDecoration(
          color: cs.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: job.isOverdue
                ? cs.error.withOpacity(0.5)
                : cs.outlineVariant.withOpacity(0.4),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.04),
              blurRadius: 4,
              offset: const Offset(0, 2),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Top row: job# + status chip
              Row(
                children: [
                  Text(job.jobNumber,
                      style: tt.labelSmall?.copyWith(color: cs.outline)),
                  const Spacer(),
                  if (job.pendingSync)
                    Padding(
                      padding: const EdgeInsets.only(right: 6),
                      child: Icon(Icons.cloud_upload_outlined,
                          size: 14, color: cs.tertiary),
                    ),
                  _StatusChip(status: job.status, isOverdue: job.isOverdue),
                ],
              ),
              const SizedBox(height: 6),
              Text(job.title,
                  style: tt.titleSmall?.copyWith(fontWeight: FontWeight.w600),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis),
              const SizedBox(height: 4),
              Row(
                children: [
                  Icon(Icons.person_outline, size: 14, color: cs.outline),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(job.customerName,
                        style: tt.bodySmall?.copyWith(color: cs.onSurfaceVariant),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis),
                  ),
                  if (job.distanceKm != null) ...[
                    Icon(Icons.near_me_outlined, size: 12, color: cs.outline),
                    const SizedBox(width: 2),
                    Text('${job.distanceKm!.toStringAsFixed(1)} km',
                        style: tt.labelSmall?.copyWith(color: cs.outline)),
                  ],
                ],
              ),
              const SizedBox(height: 2),
              Row(
                children: [
                  Icon(
                    job.isOverdue ? Icons.warning_amber_rounded : Icons.schedule,
                    size: 14,
                    color: job.isOverdue ? cs.error : cs.outline,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    job.isOverdue ? 'OVERDUE · $timeStr' : timeStr,
                    style: tt.bodySmall?.copyWith(
                      color: job.isOverdue ? cs.error : cs.outline,
                      fontWeight: job.isOverdue ? FontWeight.w600 : null,
                    ),
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

class _StatusChip extends StatelessWidget {
  final String status;
  final bool isOverdue;
  const _StatusChip({required this.status, required this.isOverdue});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;

    final (label, bg, fg) = switch (status) {
      'pending' => ('Pending', cs.secondaryContainer, cs.onSecondaryContainer),
      'in_progress' => ('In Progress', cs.primaryContainer, cs.onPrimaryContainer),
      'completed' => ('Completed', const Color(0xFFD4EDDA), const Color(0xFF155724)),
      'on_hold' => ('On Hold', const Color(0xFFFFF3CD), const Color(0xFF856404)),
      'cancelled' => ('Cancelled', cs.surfaceContainerHighest, cs.outline),
      _ => (status, cs.surfaceContainerHighest, cs.outline),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: isOverdue ? cs.errorContainer : bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        isOverdue ? 'OVERDUE' : label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: isOverdue ? cs.onErrorContainer : fg,
          letterSpacing: 0.3,
        ),
      ),
    );
  }
}

// Skeleton loader — shown during initial load, prevents layout shift
class _JobListSkeleton extends StatelessWidget {
  const _JobListSkeleton();

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      itemCount: 8,
      itemBuilder: (_, __) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Container(
          height: 100,
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
        ),
      ),
    );
  }
}

class _SyncBadge extends StatelessWidget {
  final int count;
  final bool isSyncing;
  final VoidCallback onTap;

  const _SyncBadge({
    required this.count,
    required this.isSyncing,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        margin: const EdgeInsets.symmetric(vertical: 8),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(20),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isSyncing)
              const SizedBox(
                width: 12, height: 12,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            else
              Icon(Icons.cloud_upload_outlined, size: 14,
                  color: Theme.of(context).colorScheme.onTertiaryContainer),
            const SizedBox(width: 4),
            Text(
              '$count pending',
              style: TextStyle(
                fontSize: 12, fontWeight: FontWeight.w600,
                color: Theme.of(context).colorScheme.onTertiaryContainer,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
