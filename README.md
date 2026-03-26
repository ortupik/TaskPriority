# FieldPulse

Mobile job management platform for field service technicians. Built with Flutter (iOS + Android) and Django.

---
## Demo Video
https://jumpshare.com/folder/qJhJZVTw1AXlYmtJssAO

## Quick Start (Docker — recommended)

**Prerequisites:** Docker Desktop, Flutter SDK ≥ 3.3

```bash
# 1. Clone and enter project
git clone <repo-url>
cd backend

# 2. Start backend (Django + PostgreSQL + MinIO)
docker compose up --build

# The first start will:
#   - Run database migrations
#   - Seed 120 sample jobs with realistic data
#   - Start API at http://localhost:8000

# 3. Verify backend
curl http://localhost:8000/health/
# → {"status": "ok", "service": "fieldpulse-api"}

# 4. Run Flutter app
cd flutter_app
flutter pub get
flutter run --dart-define=BASE_URL=http://10.0.2.2:8000  # Android emulator
# OR
flutter run --dart-define=BASE_URL=http://localhost:8000  # iOS simulator

# 5. Log in with seeded credentials
#    Email:    tech1@fieldpulse.dev
#    Password: tech123
```

**MinIO Console** (file storage UI): http://localhost:9001  
Login: `minioadmin` / `minioadmin`

---

## Manual Backend Setup (without Docker)

```bash
cd backend

# Python 3.11+
python -m venv venv
source venv/bin/activate  # Windows: venv\Scripts\activate
pip install -r requirements.txt

# Configure environment
cp ../.env.example .env
# Edit .env — set DB_HOST=localhost

# Run migrations
python manage.py migrate

# Seed data
python manage.py seed --jobs 120

# Start development server
python manage.py runserver
```

---

## Running Tests

### Backend (Django)

```bash
cd backend
python manage.py test tests --verbosity=2
```

Covers:
- Auth flow: login, token rotation, logout, reuse detection
- Job API: list filtering, detail, status transitions, conflict detection
- Checklist flow: partial drafts, merge, validation, submission
- Unit: all validation rules (text, number, email, select, multi-select)

### Flutter (unit tests)

```bash
cd flutter_app
flutter test test/unit_test.dart --reporter=expanded
```

Covers:
- Form field validation (all types + edge cases)
- Status transition guards
- Sync queue ordering logic

### Flutter (integration / E2E with Detox)

```bash
cd flutter_app
# Install Detox (requires Node.js)
npm install -g detox-cli
yarn install

# iOS
detox build --configuration ios.sim.debug
detox test --configuration ios.sim.debug

# Android
detox build --configuration android.emu.debug
detox test --configuration android.emu.debug
```

---

## API Reference

Base URL: `http://localhost:8000/api/v1`

### Auth
| Method | Path | Description |
|--------|------|-------------|
| POST | `/auth/login/` | Email + password → JWT pair |
| POST | `/auth/refresh/` | Rotate refresh token |
| POST | `/auth/logout/` | Revoke all refresh tokens |
| GET | `/auth/me/` | Current user profile |
| POST | `/auth/fcm-token/` | Register push notification token |

### Jobs
| Method | Path | Description |
|--------|------|-------------|
| GET | `/jobs/` | List jobs (filter: status, priority, search, date range) |
| GET | `/jobs/{id}/` | Job detail with customer, schema, photos |
| PATCH | `/jobs/{id}/status/` | Update status (with conflict detection) |
| POST | `/jobs/{id}/photos/` | Upload photo (multipart) |
| DELETE | `/jobs/{id}/photos/{photo_id}/` | Delete photo |
| GET | `/jobs/sync-status/?since=<ISO>` | Count of changed jobs since timestamp |

**Delta sync:** Pass `updated_after=<ISO datetime>` to `/jobs/` to fetch only changed records.

**Pagination:** Cursor-based. Response includes `pagination.next_cursor` — pass as `cursor=` param.

**Conflict detection:** Pass `client_version` in status PATCH. Server returns 409 with `server_job` payload if version mismatch.

### Checklists
| Method | Path | Description |
|--------|------|-------------|
| GET | `/checklists/schemas/` | List active schemas |
| GET | `/checklists/schemas/{id}/` | Schema detail |
| GET | `/checklists/jobs/{job_id}/response/` | Get response for job |
| POST | `/checklists/jobs/{job_id}/draft/` | Save partial draft (merges answers) |
| POST | `/checklists/jobs/{job_id}/submit/` | Submit completed checklist |

---

## Architecture Overview

### Offline-First Data Flow

```
User Action
    │
    ▼
SQLite (immediate write)       ← source of truth
    │
    ├─ pendingSync = true
    │
ConnectivityWatcher
    │  (reconnect detected)
    ▼
SyncEngine.flush()
    ├─ 1. Job status updates  (PATCH /jobs/{id}/status/)
    ├─ 2. Checklist drafts    (POST /checklists/jobs/{id}/draft/)
    └─ 3. Photo uploads       (POST /jobs/{id}/photos/, with retry)
```

### Conflict Resolution

When the server returns `409 VERSION_CONFLICT`:
1. App stores both server and local versions
2. UI shows conflict dialog with version numbers
3. User chooses: **Keep My Changes** or **Use Server Version**
4. Choice is applied to local SQLite and re-synced

### Photo Pipeline

```
Camera capture
    ↓
EXIF auto-rotate (bakeOrientation)
    ↓
Resize (max 1200px longest edge, bicubic)
    ↓
Timestamp overlay (burned into pixels)
    ↓
JPEG encode (80% quality)
    ↓
Save to app documents directory
    ↓
Enqueue in PhotoQueue (SQLite)
    ↓
Background upload with retry (max 3 attempts)
```

### Token Security

- Access tokens: 15 minutes, JWT HS256
- Refresh tokens: 7 days, stored as SHA-256 hash in PostgreSQL
- Rotation: each refresh issues a new pair and revokes the old one
- Reuse detection: if a revoked token is replayed, entire family is revoked
- Storage: iOS Keychain / Android Keystore via `flutter_secure_storage`

---

## Known Limitations

1. **No real-time updates** — job list requires manual pull-to-refresh or app reopen to see dispatcher changes. WebSocket support would be the next step.

2. **Photo GPS** — GPS coordinates are captured client-side and stored in photo metadata. EXIF GPS embedding into the JPEG file itself is not implemented (coordinates are stored in the database only).

3. **Biometric** — Biometric unlock reuses the stored refresh token. If the refresh token expires while the app is backgrounded, biometric unlock will fail and the user must re-enter credentials.

4. **Detox E2E** — The E2E test scaffold is configured but requires a running backend at `localhost:8000`. The test suite seeds its own test user on startup.

5. **Pagination in offline mode** — The full job list is synced on login and pull-to-refresh. Mid-sync pagination cursor errors (if the server list changes) are handled gracefully but may result in duplicate upserts (idempotent).

6. **Notifications** — FCM integration requires a real `FCM_SERVER_KEY`. Push delivery is not tested in the Docker dev environment.
