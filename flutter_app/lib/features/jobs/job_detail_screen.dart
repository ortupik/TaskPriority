import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../../core/sync/sync_engine.dart';
import '../checklist/checklist_screen.dart';
import 'job_repository.dart';

class JobDetailScreen extends ConsumerStatefulWidget {
  final String jobId;
  const JobDetailScreen({super.key, required this.jobId});

  @override
  ConsumerState<JobDetailScreen> createState() => _JobDetailScreenState();
}

class _JobDetailScreenState extends ConsumerState<JobDetailScreen> {
  JobModel? _job;
  bool _isLoading = true;
  bool _isUpdating = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final repo = ref.read(jobRepositoryProvider);
    final job = await repo.getLocalJob(widget.jobId);
    // Inside build() or _load()
    if (job != null) {
      debugPrint('--- [DEBUG: JOB DATA] ---');
      debugPrint(job.toString());
      debugPrint('-------------------------');
    }
    if (mounted)
      setState(() {
        _job = job;
        _isLoading = false;
      });
  }

  Future<void> _updateStatus(String newStatus) async {
    if (_job == null) return;
    setState(() => _isUpdating = true);
    try {
      await ref.read(jobRepositoryProvider).updateStatus(
            widget.jobId,
            newStatus,
            _job!.version,
          );
      await _load();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Status updated to ${_statusLabel(newStatus)}')),
        );
      }
    } on ConflictException catch (conflict) {
      if (mounted) _showConflictDialog(conflict);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
              content: Text('Update failed: $e'), backgroundColor: Colors.red),
        );
      }
    } finally {
      if (mounted) setState(() => _isUpdating = false);
    }
  }

  void _showConflictDialog(ConflictException conflict) {
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (_) => AlertDialog(
        title: const Row(children: [
          Icon(Icons.warning_amber_rounded, color: Colors.orange),
          SizedBox(width: 8),
          Text('Sync Conflict'),
        ]),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'This job was modified by someone else while you were offline.',
              style: TextStyle(fontSize: 14),
            ),
            const SizedBox(height: 12),
            _ConflictRow('Your version', 'v${conflict.clientVersion}',
                Colors.blue.shade100),
            const SizedBox(height: 6),
            _ConflictRow('Server version', 'v${conflict.serverVersion}',
                Colors.orange.shade100),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.pop(context);
              await ref.read(jobRepositoryProvider).resolveConflictAcceptServer(
                    widget.jobId,
                    conflict.serverJob,
                  );
              await _load();
            },
            child: const Text('Use Server Version'),
          ),
          FilledButton(
            onPressed: () async {
              Navigator.pop(context);
              await ref.read(jobRepositoryProvider).resolveConflictKeepLocal(
                    widget.jobId,
                    _job!.status,
                  );
              await _load();
            },
            child: const Text('Keep My Changes'),
          ),
        ],
      ),
    );
  }

  void _launchMaps() {
	  if (_job == null) return;
	  final lat = _job!.customerLat;
	  final lng = _job!.customerLng;
	  final address = Uri.encodeComponent(_job!.customerAddress);

	  final Uri url;
	  if (lat != null && lng != null) {
		// Use coordinates for precision
		url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$lat,$lng');
	  } else {
		// Fallback to address search
		url = Uri.parse('https://www.google.com/maps/search/?api=1&query=$address');
	  }
	  launchUrl(url, mode: LaunchMode.externalApplication);
}

  void _callCustomer() {
    final phone = _job?.customerPhone;
    if (phone == null || phone.isEmpty) return;
    launchUrl(Uri.parse('tel:$phone'));
  }

  void _openChecklist() {
    final job = _job;
    if (job == null || job.checklistSchema == null) return;
    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ChecklistScreen(
          jobId: job.id,
          schema: job.checklistSchema!,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return const Scaffold(body: Center(child: CircularProgressIndicator()));
    }
    if (_job == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Job Not Found')),
        body: const Center(child: Text('This job could not be found.')),
      );
    }

    final job = _job!;
    debugPrint('JOB: $job');
    final cs = Theme.of(context).colorScheme;

    return Scaffold(
      appBar: AppBar(
        title: Text(job.jobNumber,
            style: const TextStyle(fontFamily: 'monospace')),
        actions: [
          if (job.pendingSync)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Icon(Icons.cloud_upload_outlined,
                  color: cs.tertiary, size: 20),
            ),
        ],
      ),
      // ── Sticky bottom action bar ──────────────────────────────────────
      bottomNavigationBar: _BottomActionBar(
        job: job,
        onOpenChecklist: job.hasChecklist ? _openChecklist : null,
        onNavigate: _launchMaps,
      ),
      body: RefreshIndicator(
        onRefresh: _load,
        child: SingleChildScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _StatusCard(
                  job: job,
                  isUpdating: _isUpdating,
                  onUpdateStatus: _updateStatus),
              const SizedBox(height: 16),
              _CustomerCard(
                  job: job, onNavigate: _launchMaps, onCall: _callCustomer),
              const SizedBox(height: 16),
              _ScheduleCard(job: job),
              const SizedBox(height: 16),
              if (job.description.isNotEmpty || job.notes.isNotEmpty) ...[
                _NotesCard(job: job),
                const SizedBox(height: 16),
              ],
              // Extra space so content isn't hidden behind the bottom bar
              const SizedBox(height: 80),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Bottom action bar ─────────────────────────────────────────────────────

class _BottomActionBar extends StatelessWidget {
  final JobModel job;
  final VoidCallback? onOpenChecklist;
  final VoidCallback onNavigate;

  const _BottomActionBar({
    required this.job,
    required this.onOpenChecklist,
    required this.onNavigate,
  });

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final isCompleted = job.status == 'completed';

    return SafeArea(
      child: Container(
        decoration: BoxDecoration(
          color: cs.surface,
          border: Border(top: BorderSide(color: cs.outlineVariant, width: 1)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.06),
              blurRadius: 8,
              offset: const Offset(0, -2),
            ),
          ],
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: Row(
          children: [
            // Navigate button — always visible, secondary style
            Expanded(
              flex: 2,
              child: OutlinedButton.icon(
                onPressed: onNavigate,
                icon: const Icon(Icons.navigation_outlined, size: 18),
                label: const Text('Navigate'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(48),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
              ),
            ),

            // Checklist button — only when job has a checklist
            if (job.hasChecklist) ...[
              const SizedBox(width: 10),
              Expanded(
                flex: 3,
                child: FilledButton.icon(
                  onPressed: onOpenChecklist,
                  icon: Icon(
                    isCompleted
                        ? Icons.assignment_turned_in_outlined
                        : Icons.assignment_outlined,
                    size: 18,
                  ),
                  label:
                      Text(isCompleted ? 'View Checklist' : 'Open Checklist'),
                  style: FilledButton.styleFrom(
                    minimumSize: const Size.fromHeight(48),
                    backgroundColor: isCompleted ? cs.secondary : null,
                    foregroundColor: isCompleted ? cs.onSecondary : null,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ── Cards (unchanged from original) ──────────────────────────────────────

class _StatusCard extends StatelessWidget {
  final JobModel job;
  final bool isUpdating;
  final ValueChanged<String> onUpdateStatus;

  const _StatusCard({
    required this.job,
    required this.isUpdating,
    required this.onUpdateStatus,
  });

  static const _transitions = {
    'pending': ['in_progress', 'on_hold', 'cancelled'],
    'in_progress': ['completed', 'on_hold'],
    'on_hold': ['in_progress', 'cancelled'],
    'completed': <String>[],
    'cancelled': <String>[],
  };

  @override
  Widget build(BuildContext context) {
    final available = _transitions[job.status] ?? [];
    final cs = Theme.of(context).colorScheme;

    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('Status',
                    style: Theme.of(context)
                        .textTheme
                        .labelMedium
                        ?.copyWith(color: cs.outline)),
                const Spacer(),
                if (isUpdating)
                  const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _StatusBadge(status: job.status, isOverdue: job.isOverdue),
                const Spacer(),
                if (available.isNotEmpty)
                  PopupMenuButton<String>(
                    onSelected: onUpdateStatus,
                    itemBuilder: (_) => available
                        .map((s) => PopupMenuItem(
                            value: s, child: Text(_statusLabel(s))))
                        .toList(),
                    child: Row(children: [
                      Text('Update',
                          style: TextStyle(color: cs.primary, fontSize: 14)),
                      Icon(Icons.arrow_drop_down, color: cs.primary),
                    ]),
                  ),
              ],
            ),
            if (job.isOverdue) ...[
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  color: cs.errorContainer,
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(children: [
                  Icon(Icons.warning_amber_rounded,
                      size: 16, color: cs.onErrorContainer),
                  const SizedBox(width: 6),
                  Text('This job is overdue',
                      style: TextStyle(
                          color: cs.onErrorContainer,
                          fontWeight: FontWeight.w500)),
                ]),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _CustomerCard extends StatelessWidget {
  final JobModel job;
  final VoidCallback onNavigate;
  final VoidCallback onCall;

  const _CustomerCard({
    required this.job,
    required this.onNavigate,
    required this.onCall,
  });

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Customer',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 10),
            Text(job.customerName,
                style: Theme.of(context)
                    .textTheme
                    .titleMedium
                    ?.copyWith(fontWeight: FontWeight.w600)),
            const SizedBox(height: 8),
            InkWell(
              onTap: onNavigate,
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Icon(Icons.location_on_outlined,
                        size: 16, color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(job.customerAddress,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          )),
                    ),
                  ],
                ),
              ),
            ),
            if (job.customerPhone.isNotEmpty) ...[
              const SizedBox(height: 4),
              InkWell(
                onTap: onCall,
                borderRadius: BorderRadius.circular(8),
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    children: [
                      Icon(Icons.phone_outlined,
                          size: 16,
                          color: Theme.of(context).colorScheme.primary),
                      const SizedBox(width: 6),
                      Text(job.customerPhone,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.primary,
                            decoration: TextDecoration.underline,
                          )),
                    ],
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _ScheduleCard extends StatelessWidget {
  final JobModel job;
  const _ScheduleCard({required this.job});

  @override
  Widget build(BuildContext context) {
    final fmt = DateFormat('EEE, MMM d, y · h:mm a');
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Schedule',
                style: Theme.of(context)
                    .textTheme
                    .labelMedium
                    ?.copyWith(color: Theme.of(context).colorScheme.outline)),
            const SizedBox(height: 10),
            _ScheduleRow('Start', fmt.format(job.scheduledStart.toLocal())),
            const SizedBox(height: 4),
            _ScheduleRow('End', fmt.format(job.scheduledEnd.toLocal())),
            if (job.actualStart != null) ...[
              const Divider(height: 20),
              _ScheduleRow(
                  'Actual Start', fmt.format(job.actualStart!.toLocal()),
                  color: Colors.green.shade700),
              if (job.actualEnd != null) ...[
                const SizedBox(height: 4),
                _ScheduleRow('Actual End', fmt.format(job.actualEnd!.toLocal()),
                    color: Colors.green.shade700),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

class _ScheduleRow extends StatelessWidget {
  final String label;
  final String value;
  final Color? color;

  const _ScheduleRow(this.label, this.value, {this.color});

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        SizedBox(
          width: 90,
          child: Text(label,
              style: Theme.of(context)
                  .textTheme
                  .bodySmall
                  ?.copyWith(color: Theme.of(context).colorScheme.outline)),
        ),
        Expanded(
            child: Text(value,
                style: TextStyle(fontWeight: FontWeight.w500, color: color))),
      ],
    );
  }
}

class _NotesCard extends StatelessWidget {
  final JobModel job;
  const _NotesCard({required this.job});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (job.description.isNotEmpty) ...[
              Text('Description',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.outline)),
              const SizedBox(height: 6),
              Text(job.description),
            ],
            if (job.notes.isNotEmpty) ...[
              if (job.description.isNotEmpty) const SizedBox(height: 12),
              Text('Notes',
                  style: Theme.of(context)
                      .textTheme
                      .labelMedium
                      ?.copyWith(color: Theme.of(context).colorScheme.outline)),
              const SizedBox(height: 6),
              Text(job.notes),
            ],
          ],
        ),
      ),
    );
  }
}

class _StatusBadge extends StatelessWidget {
  final String status;
  final bool isOverdue;
  const _StatusBadge({required this.status, required this.isOverdue});

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final (bg, fg) = switch (status) {
      'pending' => (cs.secondaryContainer, cs.onSecondaryContainer),
      'in_progress' => (cs.primaryContainer, cs.onPrimaryContainer),
      'completed' => (const Color(0xFFD4EDDA), const Color(0xFF155724)),
      'on_hold' => (const Color(0xFFFFF3CD), const Color(0xFF856404)),
      _ => (cs.surfaceContainerHighest, cs.outline),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: isOverdue ? cs.errorContainer : bg,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        _statusLabel(isOverdue ? 'overdue' : status),
        style: TextStyle(
          fontWeight: FontWeight.w600,
          fontSize: 13,
          color: isOverdue ? cs.onErrorContainer : fg,
        ),
      ),
    );
  }
}

class _ConflictRow extends StatelessWidget {
  final String label;
  final String value;
  final Color bg;
  const _ConflictRow(this.label, this.value, this.bg);

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration:
          BoxDecoration(color: bg, borderRadius: BorderRadius.circular(6)),
      child: Row(
        children: [
          Text(label, style: const TextStyle(fontSize: 13)),
          const Spacer(),
          Text(value,
              style:
                  const TextStyle(fontWeight: FontWeight.w600, fontSize: 13)),
        ],
      ),
    );
  }
}

String _statusLabel(String status) => switch (status) {
      'pending' => 'Pending',
      'in_progress' => 'In Progress',
      'completed' => 'Completed',
      'on_hold' => 'On Hold',
      'cancelled' => 'Cancelled',
      'overdue' => 'Overdue',
      _ => status,
    };

class ConflictException implements Exception {
  final int serverVersion;
  final int clientVersion;
  final Map<String, dynamic> serverJob;
  const ConflictException({
    required this.serverVersion,
    required this.clientVersion,
    required this.serverJob,
  });
}
