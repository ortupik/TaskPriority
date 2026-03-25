# Architecture Decisions

## State Management: Riverpod

**Chosen over:** Bloc, Provider, MobX

**Why Riverpod:**
The key selling point was compile-time safety for provider dependencies. With Bloc, wiring an `AuthBloc` to a `JobBloc` requires passing cubit references through constructors or using `BlocProvider.of`. With Riverpod, dependencies are declared directly in `build()`:

```dart
@riverpod
JobRepository jobRepository(Ref ref) {
  return JobRepository(ref.read(apiClientProvider), ref.read(appDatabaseProvider));
}
```

The dependency graph is explicit and testable. Providers are lazily initialized and auto-disposed when no longer watched — critical for memory efficiency with 500+ job list items.

`AsyncNotifier` handles loading/error/data states in one type without the boilerplate of three separate Bloc states. For something like the sync engine which needs to react to connectivity changes and expose loading state, a 3-state sealed class in Bloc would have been ~60 lines vs ~15 with Riverpod's `StreamProvider`.

**Trade-off:** The `@riverpod` annotation codegen requires a build step (`dart run build_runner build`). This adds ~5s to the development loop. For a team unfamiliar with codegen this is friction, but the type safety is worth it.

---

## Offline Sync: Write-through SQLite with Optimistic Queue

**The core principle:** Every write goes to SQLite first. The server is a sync target, not the source of truth during a session.

**Why not just cache API responses:**
Caching responses (like Hive + background fetch) leaves the app in an inconsistent state when offline — the user can *see* jobs but can't modify them. True offline-first means the app is fully functional with no connectivity, and syncs changes opportunistically.

**Queue design:**
```
Jobs → Checklists → Photos  (strict ordering)
```
This ordering matters: a checklist submission references a job that must already exist on the server. A photo references a checklist field. Inverting this would cause foreign key errors on the server during conflict periods.

**Why Drift (not sqflite directly):**
Drift gives type-safe queries generated at compile time. `sqflite` raw SQL with string interpolation is a category of bug waiting to happen. The schema definition in `app_database.dart` is the single source of truth — migrations are generated automatically.

**What I'd improve with more time:**
Replace the batch-on-reconnect sync with a proper sync log replay (event sourcing style). Currently if a sync partially fails (3 of 5 items succeed), the failed items stay in the queue but there's no way to know which succeeded. An append-only event log would make this idempotent and recoverable.

---

## Conflict Resolution: Version-Based with User Choice

**How it works:**
1. Every `Job` row has a `version` counter that increments on every server-side write.
2. When the Flutter app updates a job status, it sends `client_version` with the request.
3. If `server.version > client_version`, the server returns `409 VERSION_CONFLICT` with the full server-side job payload.
4. The app shows a conflict dialog: **Keep My Changes** or **Use Server Version**.

**Why not last-write-wins:**
Field technicians making offline changes have ground truth (they're standing in front of the equipment). Auto-accepting server overwrites would silently discard work. The conflict dialog is one extra tap but prevents data loss.

**Why not three-way merge by default:**
Three-way merge makes sense for text fields (notes, description) where partial changes can coexist. For status fields it makes no sense — a job is either `completed` or it isn't. The merge option is reserved for a future "advanced conflict" UI where text fields can be compared line-by-line.

**Trade-off:** In practice, conflicts are rare. The version check adds ~10 bytes to every status update payload for a rare code path. Worth it for correctness.

---

## Checklist Schema: Backend-Defined JSON

**Why not hardcoded field types in the app:**
The spec says field sets vary per job type. If we hardcode schema in Flutter, adding a new field type requires an app store release. With a backend schema, dispatchers can create new inspection templates immediately.

**Schema format design:**
```json
{
  "id": "field_uuid",
  "type": "select",
  "label": "Result",
  "required": true,
  "order": 3,
  "options": ["Pass", "Fail"],
  "validation": { "min_length": 5 }
}
```
The `order` field allows reordering without changing IDs. The `id` is stable across schema versions — responses reference field IDs, not positions. If a schema is updated, old responses remain valid because the IDs don't change.

**Schema versioning:**
`ChecklistResponse` stores `schema_version` at submission time. This means historical responses can always be rendered correctly even if the schema evolves.

---

## JWT Implementation: Custom over djangorestframework-simplejwt

**Why custom:**
`simplejwt` stores no server-side state by default — refresh tokens are self-contained JWTs. This means there's no way to revoke a specific device's session or detect token reuse.

The custom implementation stores a SHA-256 hash of the refresh token in PostgreSQL with a `revoked_at` timestamp. This enables:
- Per-device logout (revoke only that device's token)
- Token family revocation on detected reuse (security response)
- Audit trail of all token issuances

**Trade-off:** Requires a DB read on every refresh. At scale, this would use a Redis cache keyed on the token hash. For this project, PostgreSQL with the `token` index is fast enough (<2ms).

---

## Photo Processing: Client-Side First, Server as Backstop

**Client does:** EXIF rotation, resize to 1200px, JPEG encode at 80%, timestamp overlay.

**Why client-side:**
1. Reduces upload size 60-80% (raw camera JPEG on iPhone 15 Pro is ~8MB; processed is ~200-400KB).
2. Timestamp is burned in before any compression artifacts, so it's always readable.
3. Faster perceived performance — user sees the thumbnail immediately, upload is background.

**Server does:** Size check (reject >10MB), store to MinIO, generate presigned URL.

The server doesn't re-compress because the client already did it correctly. If the client sends an oversized image (e.g. gallery selection bypass), the server rejects it.

**EXIF orientation:** The `image` package's `bakeOrientation()` reads the EXIF orientation tag and physically rotates the pixels, then strips the tag. This prevents the "sideways photo" bug common when displaying raw camera output on web.

---

## What I'd Do Differently With More Time

1. **WebSocket sync** — Replace polling/pull-to-refresh with a WebSocket channel. Dispatchers assigning jobs in real-time would appear on the technician's device within seconds.

2. **Background sync on iOS** — Use `BGProcessingTask` to sync when the app is backgrounded. Currently sync only fires on foreground + reconnect.

3. **Proper E2E test isolation** — The Detox tests hit a live backend. A better setup uses a mock server (MSW or a dedicated test Django instance with a reset endpoint) so E2E tests are fully deterministic.

4. **Photo GPS EXIF embedding** — Currently GPS coordinates are stored in the database. For true forensic photo evidence, they should be embedded in the JPEG EXIF data. The `image` package supports this; it's a 10-line addition.

5. **Offline map tiles** — The current maps integration launches the native maps app. For truly offline use (no connectivity), pre-cached map tiles (e.g. Mapbox offline) would let technicians see maps without any network.

6. **Schema migration UI** — When a `ChecklistSchema` is updated, in-progress jobs that were cached with the old schema should show a "Schema updated" banner and reload. Currently the app uses the cached schema until next full sync.
