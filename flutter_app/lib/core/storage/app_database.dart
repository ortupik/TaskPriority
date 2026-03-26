import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:path_provider/path_provider.dart';
import 'package:path/path.dart' as p;
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

part 'app_database.g.dart';

// ── Table definitions ─────────────────────────────────────────────────────

class Jobs extends Table {
  TextColumn get id => text()();
  TextColumn get jobNumber => text()();
  TextColumn get title => text()();
  TextColumn get description => text().withDefault(const Constant(''))();
  TextColumn get notes => text().withDefault(const Constant(''))();
  TextColumn get status => text()();
  TextColumn get priority => text()();
  TextColumn get customerId => text()();
  TextColumn get customerName => text()();
  TextColumn get customerAddress => text()();
  TextColumn get customerPhone => text().withDefault(const Constant(''))();
  RealColumn get customerLat => real().nullable()();
  RealColumn get customerLng => real().nullable()();
  TextColumn get assignedToName => text().withDefault(const Constant(''))();
  DateTimeColumn get scheduledStart => dateTime()();
  DateTimeColumn get scheduledEnd => dateTime()();
  DateTimeColumn get actualStart => dateTime().nullable()();
  DateTimeColumn get actualEnd => dateTime().nullable()();
  TextColumn get checklistSchemaJson => text().nullable()(); // full schema JSON
  IntColumn get version => integer().withDefault(const Constant(1))();
  BoolColumn get isOverdue => boolean().withDefault(const Constant(false))();
  DateTimeColumn get updatedAt => dateTime()();
  // Sync state
  BoolColumn get pendingSync => boolean().withDefault(const Constant(false))();
  TextColumn get pendingSyncAction => text().nullable()(); // 'status_update' | 'checklist_submit'

  @override
  Set<Column> get primaryKey => {id};
}

class ChecklistDrafts extends Table {
  TextColumn get jobId => text()();
  TextColumn get schemaId => text()();
  TextColumn get answersJson => text().withDefault(const Constant('{}'))();
  TextColumn get status => text().withDefault(const Constant('draft'))(); // draft | submitted
  DateTimeColumn get updatedAt => dateTime()();
  BoolColumn get pendingSync => boolean().withDefault(const Constant(false))();

  @override
  Set<Column> get primaryKey => {jobId};
}

class PhotoQueue extends Table {
  TextColumn get id => text()(); // local UUID
  TextColumn get jobId => text()();
  TextColumn get localPath => text()();
  TextColumn get checklistFieldId => text().withDefault(const Constant(''))();
  RealColumn get latitude => real().nullable()();
  RealColumn get longitude => real().nullable()();
  DateTimeColumn get capturedAt => dateTime()();
  IntColumn get retryCount => integer().withDefault(const Constant(0))();
  TextColumn get uploadStatus => text().withDefault(const Constant('pending'))();
  // 'pending' | 'uploading' | 'uploaded' | 'failed'
  TextColumn get remoteId => text().nullable()(); // server-assigned ID after upload
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get createdAt => dateTime()();

  @override
  Set<Column> get primaryKey => {id};
}

class SyncLog extends Table {
  IntColumn get id => integer().autoIncrement()();
  TextColumn get entityType => text()(); // 'job' | 'checklist' | 'photo'
  TextColumn get entityId => text()();
  TextColumn get action => text()();
  TextColumn get status => text()(); // 'success' | 'failed' | 'conflict'
  TextColumn get errorMessage => text().nullable()();
  DateTimeColumn get occurredAt => dateTime()();
}

// ── Database ──────────────────────────────────────────────────────────────

@DriftDatabase(tables: [Jobs, ChecklistDrafts, PhotoQueue, SyncLog])
class AppDatabase extends _$AppDatabase {
  AppDatabase() : super(_openConnection());

  @override
  int get schemaVersion => 1;

  // ── Jobs ────────────────────────────────────────────────────────────────

  Future<List<Job>> getAllJobs() => select(jobs).get();

  Future<Job?> getJob(String id) =>
      (select(jobs)..where((t) => t.id.equals(id))).getSingleOrNull();

  Future<void> upsertJob(JobsCompanion job) =>
      into(jobs).insertOnConflictUpdate(job);

  Future<void> upsertJobs(List<JobsCompanion> rows) =>
      batch((b) => b.insertAllOnConflictUpdate(jobs, rows));

  Future<List<Job>> getJobsForSync() =>
      (select(jobs)..where((t) => t.pendingSync.equals(true))).get();

  Future<void> markJobSyncPending(String id, String action) =>
      (update(jobs)..where((t) => t.id.equals(id))).write(
        JobsCompanion(
          pendingSync: const Value(true),
          pendingSyncAction: Value(action),
        ),
      );

  Future<void> markJobSynced(String id) =>
      (update(jobs)..where((t) => t.id.equals(id))).write(
        const JobsCompanion(
          pendingSync: Value(false),
          pendingSyncAction: Value(null),
        ),
      );

  Future<void> updateJobStatus(String id, String status) =>
      (update(jobs)..where((t) => t.id.equals(id))).write(
        JobsCompanion(status: Value(status)),
      );

  // ── Checklists ──────────────────────────────────────────────────────────

  Future<ChecklistDraft?> getDraft(String jobId) =>
      (select(checklistDrafts)..where((t) => t.jobId.equals(jobId)))
          .getSingleOrNull();

  Future<void> upsertDraft(ChecklistDraftsCompanion draft) =>
      into(checklistDrafts).insertOnConflictUpdate(draft);

  Future<List<ChecklistDraft>> getPendingDrafts() =>
      (select(checklistDrafts)..where((t) => t.pendingSync.equals(true))).get();

  Future<void> markDraftSynced(String jobId) =>
      (update(checklistDrafts)..where((t) => t.jobId.equals(jobId))).write(
        const ChecklistDraftsCompanion(pendingSync: Value(false)),
      );

  // ── Photo queue ─────────────────────────────────────────────────────────

  Future<void> enqueuePhoto(PhotoQueueCompanion photo) =>
      into(photoQueue).insert(photo);

  Future<List<PhotoQueueData>> getPendingPhotos() =>
      (select(photoQueue)..where((t) =>
          t.uploadStatus.equals('pending') | t.uploadStatus.equals('failed')))
          .get();

  Future<void> updatePhotoStatus(
      String id, String status, {String? remoteId, String? error}) =>
      (update(photoQueue)..where((t) => t.id.equals(id))).write(
        PhotoQueueCompanion(
          uploadStatus: Value(status),
          remoteId: remoteId != null ? Value(remoteId) : const Value.absent(),
          errorMessage: error != null ? Value(error) : const Value.absent(),
          retryCount: status == 'failed'
              ? const Value.absent() // incremented separately
              : const Value.absent(),
        ),
      );

  Future<void> incrementPhotoRetry(String id) => customUpdate(
        'UPDATE photo_queue SET retry_count = retry_count + 1 WHERE id = ?',
        variables: [Variable.withString(id)],
      );

  Future<List<PhotoQueueData>> getPhotosForJob(String jobId) =>
      (select(photoQueue)..where((t) => t.jobId.equals(jobId))).get();

  // ── Sync log ────────────────────────────────────────────────────────────

  Future<void> logSync({
    required String entityType,
    required String entityId,
    required String action,
    required String status,
    String? error,
  }) =>
      into(syncLog).insert(SyncLogCompanion.insert(
        entityType: entityType,
        entityId: entityId,
        action: action,
        status: status,
        errorMessage: Value(error),
        occurredAt: DateTime.now(),
      ));

  // ── Counts ──────────────────────────────────────────────────────────────

  Future<int> getPendingSyncCount() async {
    final pendingJobs = await (select(jobs)
          ..where((t) => t.pendingSync.equals(true)))
        .get();
    final pendingDrafts = await (select(checklistDrafts)
          ..where((t) => t.pendingSync.equals(true)))
        .get();
    final pendingPhotos = await (select(photoQueue)
          ..where((t) => t.uploadStatus.equals('pending') |
              t.uploadStatus.equals('failed')))
        .get();
    return pendingJobs.length + pendingDrafts.length + pendingPhotos.length;
  }
}

LazyDatabase _openConnection() {
  return LazyDatabase(() async {
    final dir = await getApplicationDocumentsDirectory();
    final file = File(p.join(dir.path, 'fieldpulse.db'));
    return driftDatabase(path: file.path);
  });
}

@riverpod
AppDatabase appDatabase(Ref ref) {
  final db = AppDatabase();
  ref.onDispose(db.close);
  return db;
}
