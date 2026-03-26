import 'dart:convert';

import 'package:drift/drift.dart' hide Column;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../core/network/api_client.dart';
import '../../core/storage/app_database.dart';
import '../../core/sync/sync_engine.dart';

part 'job_repository.g.dart';

// ── Domain model ─────────────────────────────────────────────────────────

class JobModel {
  final String id;
  final String jobNumber;
  final String title;
  final String description;
  final String notes;
  final String status;
  final String priority;
  final String customerId;
  final String customerName;
  final String customerAddress;
  final String customerPhone;
  final double? customerLat;
  final double? customerLng;
  final String assignedToName;
  final DateTime scheduledStart;
  final DateTime scheduledEnd;
  final DateTime? actualStart;
  final DateTime? actualEnd;
  final Map<String, dynamic>? checklistSchema;
  final int version;
  final bool isOverdue;
  final DateTime updatedAt;
  final bool pendingSync;
  final double? distanceKm;

  const JobModel({
    required this.id,
    required this.jobNumber,
    required this.title,
    required this.description,
    required this.notes,
    required this.status,
    required this.priority,
    required this.customerId,
    required this.customerName,
    required this.customerAddress,
    required this.customerPhone,
    this.customerLat,
    this.customerLng,
    required this.assignedToName,
    required this.scheduledStart,
    required this.scheduledEnd,
    this.actualStart,
    this.actualEnd,
    this.checklistSchema,
    required this.version,
    required this.isOverdue,
    required this.updatedAt,
    required this.pendingSync,
    this.distanceKm,
  });

  bool get hasChecklist => checklistSchema != null;
  
  Map<String, dynamic> toJson() => {
        'id': id,
        'job_number': jobNumber,
        'title': title,
        'status': status,
        'customer_name': customerName,
        'scheduled_start': scheduledStart.toIso8601String(),
        'version': version,
        'pending_sync': pendingSync,
        'is_overdue': isOverdue,
		'checklist_schema': checklistSchema, 
      };

  @override
  String toString() {
    try {
      // Using 2-space indentation for better console readability
      return const JsonEncoder.withIndent('  ').convert(toJson());
    } catch (e) {
      return 'JobModel(id: $id, jobNumber: $jobNumber)';
    }
  }

  JobModel copyWith({String? status, bool? pendingSync, int? version}) =>
      JobModel(
        id: id,
        jobNumber: jobNumber,
        title: title,
        description: description,
        notes: notes,
        status: status ?? this.status,
        priority: priority,
        customerId: customerId,
        customerName: customerName,
        customerAddress: customerAddress,
        customerPhone: customerPhone,
        customerLat: customerLat,
        customerLng: customerLng,
        assignedToName: assignedToName,
        scheduledStart: scheduledStart,
        scheduledEnd: scheduledEnd,
        actualStart: actualStart,
        actualEnd: actualEnd,
        checklistSchema: checklistSchema,
        version: version ?? this.version,
        isOverdue: isOverdue,
        updatedAt: updatedAt,
        pendingSync: pendingSync ?? this.pendingSync,
        distanceKm: distanceKm,
      );
}

// ── Repository ────────────────────────────────────────────────────────────

@riverpod
JobRepository jobRepository(Ref ref) {
  // FIX: use ref.watch() so all providers share the same singleton instances.
  // ref.read() inside a provider body can instantiate a second AppDatabase,
  // meaning writes from syncFromServer() go to a different object than the
  // one getLocalJobs() reads from — producing an empty list every time.
  return JobRepository(
    ref.watch(appDatabaseProvider),
    ref.watch(apiClientProvider),
    ref.watch(syncEngineProvider),
  );
}

class JobRepository {
  final AppDatabase _db;
  final ApiClient _api;
  final SyncEngine _sync;

  JobRepository(this._db, this._api, this._sync);

// Helper for the toDouble() error
double? _safeParseDouble(dynamic val) {
  if (val == null) return null;
  if (val is num) return val.toDouble();
  if (val is String) return double.tryParse(val);
  return null;
}

Future<void> syncFromServer({String? updatedAfter}) async {
  // 1. Initial URL: Use relative path so Dio prepends BaseURL
  String? nextUrl = Uri(
    path: 'jobs/', 
    queryParameters: {
      'page_size': '20',
      if (updatedAfter != null) 'updated_after': updatedAfter,
    },
  ).toString();

  do {
    debugPrint('--- JOBS SYNC: Requesting $nextUrl ---');
    try {
      final resp = await _api.get(nextUrl!);
      final rawBody = resp.data;
      if (rawBody is! Map) break;

      final body = Map<String, dynamic>.from(rawBody);
      final dataField = body['data'] ?? body['results'] ?? [];
      final List<dynamic> rawItems = dataField is List ? dataField : [];

      if (rawItems.isEmpty) break;

      final rows = rawItems
          .whereType<Map>()
          .map((raw) => Map<String, dynamic>.from(raw))
          .map(_apiJobToCompanion) // Ensure this uses _safeParseDouble
          .toList();

      await _db.upsertJobs(rows);
      debugPrint('JOBS SYNC: Successfully saved ${rows.length} jobs');

      // 2. Handle Pagination: The server is sending FULL URLs
      final pagination = body['pagination'];
      if (pagination is Map && pagination['has_next'] == true) {
        final cursorUrl = pagination['next_cursor']?.toString();
        
        if (cursorUrl != null) {
          // If the server gives a full URL (like in your logs), use it directly
          if (cursorUrl.startsWith('http')) {
             nextUrl = cursorUrl;
          } else {
             // Otherwise, rebuild it
             nextUrl = Uri(path: 'jobs/', queryParameters: {
               'page_size': '20',
               'cursor': cursorUrl,
             }).toString();
          }
        } else {
          nextUrl = null;
        }
      } else {
        nextUrl = null;
      }
    } catch (e) {
      debugPrint('JOBS SYNC ERROR: $e');
      break; 
    }
  } while (nextUrl != null);
}
  Future<List<JobModel>> getLocalJobs() async {
    final rows = await _db.getAllJobs();
    debugPrint('LOCAL JOBS COUNT: ${rows.length}');
    return rows.map(_rowToModel).toList();
  }

  Future<JobModel?> getLocalJob(String id) async {
    final row = await _db.getJob(id);
    return row != null ? _rowToModel(row) : null;
  }

  Future<void> updateStatus(
      String jobId, String newStatus, int currentVersion) async {
    await _db.updateJobStatus(jobId, newStatus);
    await _db.markJobSyncPending(jobId, 'status_update');
    await _sync.flush();
  }

  Future<void> resolveConflictAcceptServer(
      String jobId, Map<String, dynamic> serverJob) async {
    await _sync.acceptServerVersion(jobId, serverJob);
  }

  Future<void> resolveConflictKeepLocal(
      String jobId, String localStatus) async {
    await _api.patch('/jobs/$jobId/status/', data: {'status': localStatus});
    await _db.markJobSynced(jobId);
  }

  // ── Helpers ──────────────────────────────────────────────────────────────

  JobsCompanion _apiJobToCompanion(Map<String, dynamic> j) {
    final rawCustomer = j['customer'];
    final customer = rawCustomer is Map
        ? Map<String, dynamic>.from(rawCustomer)
        : <String, dynamic>{};

    final schema = j['checklist_schema'];

    final id = j['id']?.toString() ?? '';

    DateTime parseDate(dynamic value, {DateTime? fallback}) {
      if (value is String && value.isNotEmpty) {
        try {
          return DateTime.parse(value);
        } catch (_) {}
      }
      return fallback ?? DateTime.now();
    }

    DateTime? parseNullableDate(dynamic value) {
      if (value is String && value.isNotEmpty) {
        try {
          return DateTime.parse(value);
        } catch (_) {}
      }
      return null;
    }

    return JobsCompanion(
      id: Value(id),
      jobNumber: Value(j['job_number']?.toString() ?? ''),
      title: Value(j['title']?.toString() ?? ''),
      description: Value(j['description']?.toString() ?? ''),
      notes: Value(j['notes']?.toString() ?? ''),
      status: Value(j['status']?.toString() ?? 'pending'),
      priority: Value(j['priority']?.toString() ?? 'normal'),
      customerId: Value(j['id']?.toString() ?? ''),  // use job id as fallback
		customerName: Value(j['customer_name']?.toString() ?? ''),
		customerAddress: Value(j['customer_address']?.toString() ?? ''),
		customerPhone: Value(j['customer_phone']?.toString() ?? ''),
		customerLat: Value(_parseDouble(j['customer_lat'])), // FIXED
       customerLng: Value(_parseDouble(j['customer_lng'])), // FIXED
      assignedToName: Value(j['assigned_to_name']?.toString() ?? ''),
      scheduledStart: Value(parseDate(j['scheduled_start'])),
      scheduledEnd: Value(parseDate(j['scheduled_end'])),
      actualStart: Value(parseNullableDate(j['actual_start'])),
      actualEnd: Value(parseNullableDate(j['actual_end'])),
      checklistSchemaJson: Value(schema != null ? jsonEncode(schema) : null),
      version: Value((j['version'] as num?)?.toInt() ?? 1),
      isOverdue: Value(j['is_overdue'] == true),
      updatedAt: Value(parseDate(j['updated_at'])),
      pendingSync: const Value(false),
    );
  }

  JobModel _rowToModel(Job row) {
    Map<String, dynamic>? schema;
    if (row.checklistSchemaJson != null) {
      try {
        schema = jsonDecode(row.checklistSchemaJson!) as Map<String, dynamic>;
      } catch (_) {}
    }
    return JobModel(
      id: row.id,
      jobNumber: row.jobNumber,
      title: row.title,
      description: row.description,
      notes: row.notes,
      status: row.status,
      priority: row.priority,
      customerId: row.customerId,
      customerName: row.customerName,
      customerAddress: row.customerAddress,
      customerPhone: row.customerPhone,
      customerLat: row.customerLat,
      customerLng: row.customerLng,
      assignedToName: row.assignedToName,
      scheduledStart: row.scheduledStart,
      scheduledEnd: row.scheduledEnd,
      actualStart: row.actualStart,
      actualEnd: row.actualEnd,
      checklistSchema: schema,
      version: row.version,
      isOverdue: row.isOverdue,
      updatedAt: row.updatedAt,
      pendingSync: row.pendingSync,
    );
  }
}

// ── Extension ─────────────────────────────────────────────────────────────

extension _Let<T> on T {
  R let<R>(R Function(T) block) => block(this);
}
