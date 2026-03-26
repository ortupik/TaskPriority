/// SyncEngine — offline-first sync layer
///
/// Architecture:
///   1. Every write goes to SQLite immediately (pendingSync = true)
///   2. ConnectivityWatcher triggers flushQueue() on reconnect
///   3. flushQueue() uploads in order: job status → checklists → photos
///   4. Conflicts (version mismatch 409) are surfaced to UI for resolution
///   5. Photo retries use exponential backoff up to 3 attempts
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:dio/dio.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../app_config.dart';
import '../network/api_client.dart';
import 'app_database.dart';

part 'sync_engine.g.dart';

enum SyncStatus { idle, syncing, error }

@riverpod
class SyncNotifier extends _$SyncNotifier {
  @override
  SyncState build() {
    // Watch connectivity and trigger sync on reconnect
    ref.listen(connectivityProvider, (prev, next) {
      if (next.value == true && prev?.value != true) {
        flushQueue();
      }
    });
    return const SyncState(status: SyncStatus.idle, pendingCount: 0);
  }

  Future<void> flushQueue() async {
    if (state.status == SyncStatus.syncing) return;

    state = state.copyWith(status: SyncStatus.syncing);

    try {
      final engine = ref.read(syncEngineProvider);
      await engine.flush();
      final db = ref.read(appDatabaseProvider);
      final count = await db.getPendingSyncCount();
      state = state.copyWith(status: SyncStatus.idle, pendingCount: count);
    } catch (e) {
      state = state.copyWith(status: SyncStatus.error, lastError: e.toString());
    }
  }

  Future<void> refreshPendingCount() async {
    final db = ref.read(appDatabaseProvider);
    final count = await db.getPendingSyncCount();
    state = state.copyWith(pendingCount: count);
  }
}

class SyncState {
  final SyncStatus status;
  final int pendingCount;
  final String? lastError;
  final ConflictPayload? pendingConflict;

  const SyncState({
    required this.status,
    required this.pendingCount,
    this.lastError,
    this.pendingConflict,
  });

  SyncState copyWith({
    SyncStatus? status,
    int? pendingCount,
    String? lastError,
    ConflictPayload? pendingConflict,
  }) =>
      SyncState(
        status: status ?? this.status,
        pendingCount: pendingCount ?? this.pendingCount,
        lastError: lastError ?? this.lastError,
        pendingConflict: pendingConflict ?? this.pendingConflict,
      );
}

/// Represents a 409 conflict returned by the server.
class ConflictPayload {
  final String jobId;
  final int serverVersion;
  final int clientVersion;
  final Map<String, dynamic> serverJob;

  const ConflictPayload({
    required this.jobId,
    required this.serverVersion,
    required this.clientVersion,
    required this.serverJob,
  });
}

@riverpod
SyncEngine syncEngine(Ref ref) {
  return SyncEngine(
    ref.read(appDatabaseProvider),
    ref.read(apiClientProvider),
  );
}

class SyncEngine {
  final AppDatabase _db;
  final ApiClient _api;

  SyncEngine(this._db, this._api);

  /// Flush all pending items in dependency order.
  Future<SyncResult> flush() async {
    final result = SyncResult();

    // 1. Job status updates
    await _flushJobUpdates(result);

    // 2. Checklist submissions
    await _flushChecklists(result);

    // 3. Photos (background, with retry)
    await _flushPhotos(result);

    return result;
  }

  // ── Job status updates ──────────────────────────────────────────────────

  Future<void> _flushJobUpdates(SyncResult result) async {
    final pending = await _db.getJobsForSync();

    for (final job in pending) {
      if (job.pendingSyncAction != 'status_update') continue;
      try {
        await _api.patch(
          '/jobs/${job.id}/status/',
          data: {
            'status': job.status,
            'client_version': job.version,
          },
        );
        await _db.markJobSynced(job.id);
        await _db.logSync(
          entityType: 'job',
          entityId: job.id,
          action: 'status_update',
          status: 'success',
        );
        result.jobsUploaded++;
      } on DioException catch (e) {
        if (e.response?.statusCode == 409) {
          // Conflict — surface to UI
          final errData = e.response!.data['error']['details'] as Map;
          result.conflicts.add(ConflictPayload(
            jobId: job.id,
            serverVersion: errData['server_version'] as int,
            clientVersion: errData['client_version'] as int,
            serverJob: (errData['server_job'] as Map).cast(),
          ));
          await _db.logSync(
            entityType: 'job',
            entityId: job.id,
            action: 'status_update',
            status: 'conflict',
            error: 'Version conflict v${errData['client_version']} vs v${errData['server_version']}',
          );
        } else {
          await _db.logSync(
            entityType: 'job',
            entityId: job.id,
            action: 'status_update',
            status: 'failed',
            error: e.message,
          );
          result.errors++;
        }
      }
    }
  }

  // ── Checklist submissions ───────────────────────────────────────────────

  Future<void> _flushChecklists(SyncResult result) async {
    final pending = await _db.getPendingDrafts();

    for (final draft in pending) {
      try {
        final answers = jsonDecode(draft.answersJson) as Map<String, dynamic>;
        final endpoint = draft.status == 'submitted'
            ? '/checklists/jobs/${draft.jobId}/submit/'
            : '/checklists/jobs/${draft.jobId}/draft/';

        await _api.post(endpoint, data: {
          'answers': answers,
          'client_updated_at': draft.updatedAt.toIso8601String(),
        });

        await _db.markDraftSynced(draft.jobId);
        await _db.logSync(
          entityType: 'checklist',
          entityId: draft.jobId,
          action: draft.status,
          status: 'success',
        );
        result.checklistsUploaded++;
      } on DioException catch (e) {
        await _db.logSync(
          entityType: 'checklist',
          entityId: draft.jobId,
          action: 'sync',
          status: 'failed',
          error: e.message,
        );
        result.errors++;
      }
    }
  }

  // ── Photo uploads ───────────────────────────────────────────────────────

  Future<void> _flushPhotos(SyncResult result) async {
    final pending = await _db.getPendingPhotos();

    for (final photo in pending) {
      if (photo.retryCount >= AppConfig.photoUploadMaxRetries) {
        await _db.updatePhotoStatus(photo.id, 'failed',
            error: 'Max retries exceeded');
        continue;
      }

      final file = File(photo.localPath);
      if (!file.existsSync()) {
        await _db.updatePhotoStatus(photo.id, 'failed', error: 'File not found');
        continue;
      }

      try {
        await _db.updatePhotoStatus(photo.id, 'uploading');

        final formData = FormData.fromMap({
          'file': await MultipartFile.fromFile(
            photo.localPath,
            filename: '${photo.id}.jpg',
          ),
          if (photo.checklistFieldId.isNotEmpty)
            'checklist_field_id': photo.checklistFieldId,
          if (photo.latitude != null) 'latitude': photo.latitude.toString(),
          if (photo.longitude != null) 'longitude': photo.longitude.toString(),
          'captured_at': photo.capturedAt.toIso8601String(),
        });

        final resp = await _api.postFormData(
          '/jobs/${photo.jobId}/photos/',
          formData,
        );

        final remoteId = resp.data['id'] as String;
        await _db.updatePhotoStatus(photo.id, 'uploaded', remoteId: remoteId);
        await _db.logSync(
          entityType: 'photo',
          entityId: photo.id,
          action: 'upload',
          status: 'success',
        );
        result.photosUploaded++;
      } on DioException catch (e) {
        await _db.incrementPhotoRetry(photo.id);
        await _db.updatePhotoStatus(photo.id, 'pending',
            error: e.message); // back to pending for retry
        await _db.logSync(
          entityType: 'photo',
          entityId: photo.id,
          action: 'upload',
          status: 'failed',
          error: e.message,
        );
        result.errors++;
      }
    }
  }

  /// Accept server version — overwrite local job with server data.
  Future<void> acceptServerVersion(String jobId, Map<String, dynamic> serverJob) async {
    await _db.upsertJob(JobsCompanion(
      id: Value(jobId),
      status: Value(serverJob['status'] as String),
      version: Value(serverJob['version'] as int),
      pendingSync: const Value(false),
      pendingSyncAction: const Value(null),
      updatedAt: Value(DateTime.parse(serverJob['updated_at'] as String)),
    ));
  }

  /// Keep local — re-attempt upload ignoring version check.
  Future<void> keepLocalVersion(String jobId) async {
    // Remove version from next upload so server accepts it
    await _db.markJobSyncPending(jobId, 'status_update_force');
  }
}

class SyncResult {
  int jobsUploaded = 0;
  int checklistsUploaded = 0;
  int photosUploaded = 0;
  int errors = 0;
  List<ConflictPayload> conflicts = [];

  bool get hasConflicts => conflicts.isNotEmpty;
  int get total => jobsUploaded + checklistsUploaded + photosUploaded;
}

// ── Connectivity watcher ─────────────────────────────────────────────────

@riverpod
Stream<bool> connectivity(Ref ref) async* {
  final conn = Connectivity();
  yield* conn.onConnectivityChanged.map(
    (results) => !results.contains(ConnectivityResult.none),
  );
}
