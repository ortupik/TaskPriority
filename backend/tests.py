"""
Integration tests covering the 3 most critical API flows:
  1. Auth: login → access protected endpoint → refresh → logout
  2. Jobs: list with filters, detail, status transition with conflict detection
  3. Checklist: save draft → partial update → submit with validation
"""
from datetime import timedelta
from django.test import TestCase
from django.utils import timezone
from rest_framework.test import APIClient

from apps.accounts.models import User
from apps.checklists.models import ChecklistSchema
from apps.jobs.models import Customer, Job


def make_user(email="tech@test.com", role=User.Role.TECHNICIAN):
    user = User.objects.create_user(
        email=email,
        password="testpass123",
        first_name="Test",
        last_name="User",
        role=role,
    )
    return user


def make_customer():
    return Customer.objects.create(
        name="Acme Corp",
        phone="+1-555-000-1234",
        address_line1="123 Main St",
        city="Austin",
        state="TX",
        zip_code="78701",
        latitude=30.2672,
        longitude=-97.7431,
    )


def make_schema():
    return ChecklistSchema.objects.create(
        name="Test Schema",
        fields=[
            {"id": "f1", "type": "text", "label": "Notes", "required": True, "order": 0,
             "validation": {"min_length": 5}},
            {"id": "f2", "type": "select", "label": "Result", "required": True, "order": 1,
             "options": ["Pass", "Fail"]},
            {"id": "f3", "type": "checkbox", "label": "Confirmed", "required": False, "order": 2},
        ],
    )


def make_job(user, customer=None, schema=None, status="pending"):
    if not customer:
        customer = make_customer()
    now = timezone.now()
    return Job.objects.create(
        job_number=f"JOB-TEST-{Job.objects.count()}",
        customer=customer,
        assigned_to=user,
        created_by=user,
        title="Test Job",
        description="Test description",
        status=status,
        priority="normal",
        scheduled_start=now,
        scheduled_end=now + timedelta(hours=2),
        checklist_schema=schema,
    )


# ─────────────────────────────────────────────────────────────────────────────
# 1. AUTH FLOW
# ─────────────────────────────────────────────────────────────────────────────

class AuthFlowTest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = make_user()

    def test_login_success(self):
        resp = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com",
            "password": "testpass123",
        })
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertIn("access_token", data)
        self.assertIn("refresh_token", data)
        self.assertEqual(data["token_type"], "Bearer")
        self.assertEqual(data["user"]["email"], "tech@test.com")

    def test_login_wrong_password(self):
        resp = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com",
            "password": "wrongpassword",
        })
        self.assertEqual(resp.status_code, 400)
        self.assertEqual(resp.json()["error"]["code"], "VALIDATION_ERROR")

    def test_protected_endpoint_requires_auth(self):
        resp = self.client.get("/api/v1/jobs/")
        self.assertEqual(resp.status_code, 401)

    def test_access_with_valid_token(self):
        resp = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com", "password": "testpass123"
        })
        token = resp.json()["access_token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        resp2 = self.client.get("/api/v1/jobs/")
        self.assertEqual(resp2.status_code, 200)

    def test_refresh_token_rotation(self):
        login = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com", "password": "testpass123"
        }).json()
        refresh_resp = self.client.post("/api/v1/auth/refresh/", {
            "refresh_token": login["refresh_token"]
        })
        self.assertEqual(refresh_resp.status_code, 200)
        new_data = refresh_resp.json()
        self.assertIn("access_token", new_data)
        self.assertIn("refresh_token", new_data)
        # Old refresh token must be rejected now (rotation)
        old_reuse = self.client.post("/api/v1/auth/refresh/", {
            "refresh_token": login["refresh_token"]
        })
        self.assertEqual(old_reuse.status_code, 401)

    def test_me_endpoint(self):
        resp = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com", "password": "testpass123"
        })
        token = resp.json()["access_token"]
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {token}")
        me = self.client.get("/api/v1/auth/me/")
        self.assertEqual(me.status_code, 200)
        self.assertEqual(me.json()["email"], "tech@test.com")

    def test_logout_revokes_tokens(self):
        login = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com", "password": "testpass123"
        }).json()
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {login['access_token']}")
        self.client.post("/api/v1/auth/logout/")
        # Refresh should now fail
        resp = self.client.post("/api/v1/auth/refresh/", {
            "refresh_token": login["refresh_token"]
        })
        self.assertEqual(resp.status_code, 401)


# ─────────────────────────────────────────────────────────────────────────────
# 2. JOB API FLOW
# ─────────────────────────────────────────────────────────────────────────────

class JobAPITest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = make_user()
        self.other_user = make_user(email="other@test.com")
        self._login()

    def _login(self):
        resp = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com", "password": "testpass123"
        })
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {resp.json()['access_token']}")

    def test_job_list_only_shows_assigned_jobs(self):
        job_mine = make_job(self.user)
        job_theirs = make_job(self.other_user)
        resp = self.client.get("/api/v1/jobs/")
        self.assertEqual(resp.status_code, 200)
        ids = [j["id"] for j in resp.json()["data"]]
        self.assertIn(str(job_mine.id), ids)
        self.assertNotIn(str(job_theirs.id), ids)

    def test_job_detail(self):
        job = make_job(self.user)
        resp = self.client.get(f"/api/v1/jobs/{job.id}/")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertEqual(data["id"], str(job.id))
        self.assertIn("customer", data)
        self.assertIn("status_history", data)

    def test_cannot_access_others_job(self):
        job = make_job(self.other_user)
        resp = self.client.get(f"/api/v1/jobs/{job.id}/")
        self.assertEqual(resp.status_code, 404)

    def test_status_transition_pending_to_in_progress(self):
        job = make_job(self.user, status="pending")
        resp = self.client.patch(f"/api/v1/jobs/{job.id}/status/", {
            "status": "in_progress"
        })
        self.assertEqual(resp.status_code, 200)
        self.assertEqual(resp.json()["status"], "in_progress")
        job.refresh_from_db()
        self.assertIsNotNone(job.actual_start)

    def test_invalid_status_transition(self):
        job = make_job(self.user, status="completed")
        resp = self.client.patch(f"/api/v1/jobs/{job.id}/status/", {
            "status": "pending"
        })
        self.assertEqual(resp.status_code, 400)

    def test_version_conflict_detection(self):
        job = make_job(self.user, status="pending")
        # Simulate server being at version 3, client only knows version 1
        Job.objects.filter(pk=job.pk).update(version=3)
        resp = self.client.patch(f"/api/v1/jobs/{job.id}/status/", {
            "status": "in_progress",
            "client_version": 1,
        })
        self.assertEqual(resp.status_code, 409)
        err = resp.json()["error"]
        self.assertEqual(err["code"], "VERSION_CONFLICT")
        self.assertIn("server_version", err["details"])
        self.assertIn("server_job", err["details"])

    def test_job_list_search(self):
        c = make_customer()
        c.name = "UniqueCustomerXYZ"
        c.save()
        job = make_job(self.user, customer=c)
        resp = self.client.get("/api/v1/jobs/?search=UniqueCustomerXYZ")
        self.assertEqual(resp.status_code, 200)
        ids = [j["id"] for j in resp.json()["data"]]
        self.assertIn(str(job.id), ids)

    def test_job_list_status_filter(self):
        make_job(self.user, status="pending")
        make_job(self.user, status="completed")
        resp = self.client.get("/api/v1/jobs/?status=pending")
        self.assertEqual(resp.status_code, 200)
        statuses = [j["status"] for j in resp.json()["data"]]
        self.assertTrue(all(s == "pending" for s in statuses))


# ─────────────────────────────────────────────────────────────────────────────
# 3. CHECKLIST FLOW
# ─────────────────────────────────────────────────────────────────────────────

class ChecklistFlowTest(TestCase):
    def setUp(self):
        self.client = APIClient()
        self.user = make_user()
        self.schema = make_schema()
        self.job = make_job(self.user, schema=self.schema)
        self._login()

    def _login(self):
        resp = self.client.post("/api/v1/auth/login/", {
            "email": "tech@test.com", "password": "testpass123"
        })
        self.client.credentials(HTTP_AUTHORIZATION=f"Bearer {resp.json()['access_token']}")

    def test_save_partial_draft(self):
        resp = self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/draft/", {
            "answers": {"f1": "Some notes here"}
        }, format="json")
        self.assertEqual(resp.status_code, 201)
        data = resp.json()
        self.assertEqual(data["status"], "draft")
        self.assertEqual(data["answers"]["f1"], "Some notes here")

    def test_draft_merges_partial_saves(self):
        self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/draft/", {
            "answers": {"f1": "First save"}
        }, format="json")
        self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/draft/", {
            "answers": {"f2": "Pass"}
        }, format="json")
        resp = self.client.get(f"/api/v1/checklists/jobs/{self.job.id}/response/")
        answers = resp.json()["answers"]
        self.assertEqual(answers["f1"], "First save")
        self.assertEqual(answers["f2"], "Pass")

    def test_submit_with_validation_errors(self):
        # f1 min_length is 5, "Hi" is too short
        resp = self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/submit/", {
            "answers": {"f1": "Hi", "f2": "Pass"}
        }, format="json")
        self.assertEqual(resp.status_code, 422)
        err = resp.json()["error"]
        self.assertEqual(err["code"], "VALIDATION_ERROR")
        field_errors = err["details"]["field_errors"]
        self.assertTrue(any(e["field_id"] == "f1" for e in field_errors))

    def test_submit_missing_required_field(self):
        resp = self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/submit/", {
            "answers": {"f1": "Enough notes here"}
            # f2 (required select) is missing
        }, format="json")
        self.assertEqual(resp.status_code, 422)
        field_errors = resp.json()["error"]["details"]["field_errors"]
        self.assertTrue(any(e["field_id"] == "f2" for e in field_errors))

    def test_successful_submission(self):
        resp = self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/submit/", {
            "answers": {"f1": "All work completed successfully.", "f2": "Pass", "f3": True}
        }, format="json")
        self.assertEqual(resp.status_code, 200)
        data = resp.json()
        self.assertEqual(data["status"], "submitted")
        self.assertIsNotNone(data["submitted_at"])

    def test_cannot_resubmit(self):
        valid_answers = {"f1": "Work complete.", "f2": "Pass"}
        self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/submit/",
                         {"answers": valid_answers}, format="json")
        resp = self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/submit/",
                                {"answers": valid_answers}, format="json")
        self.assertEqual(resp.status_code, 409)

    def test_select_field_invalid_option(self):
        resp = self.client.post(f"/api/v1/checklists/jobs/{self.job.id}/submit/", {
            "answers": {"f1": "Notes here.", "f2": "NotAnOption"}
        }, format="json")
        self.assertEqual(resp.status_code, 422)
        field_errors = resp.json()["error"]["details"]["field_errors"]
        self.assertTrue(any(e["field_id"] == "f2" for e in field_errors))


# ─────────────────────────────────────────────────────────────────────────────
# UNIT: Checklist validation logic
# ─────────────────────────────────────────────────────────────────────────────

class ChecklistValidationUnitTest(TestCase):
    def _make_response(self, fields, answers):
        from apps.checklists.models import ChecklistResponse, ChecklistSchema
        schema = ChecklistSchema(fields=fields)
        resp = ChecklistResponse(schema=schema, schema_version=1, answers=answers)
        return resp

    def test_required_text_field_empty(self):
        resp = self._make_response(
            [{"id": "f1", "type": "text", "label": "Name", "required": True, "order": 0}],
            {"f1": ""}
        )
        errors = resp.validate_answers()
        self.assertEqual(len(errors), 1)
        self.assertEqual(errors[0]["field_id"], "f1")

    def test_number_min_max(self):
        resp = self._make_response(
            [{"id": "f1", "type": "number", "label": "Pressure", "required": True, "order": 0,
              "validation": {"min": 0, "max": 100}}],
            {"f1": 150}
        )
        errors = resp.validate_answers()
        self.assertEqual(len(errors), 1)
        self.assertIn("100", errors[0]["message"])

    def test_email_format_validation(self):
        resp = self._make_response(
            [{"id": "f1", "type": "text", "label": "Email", "required": True, "order": 0,
              "validation": {"format": "email"}}],
            {"f1": "not-an-email"}
        )
        errors = resp.validate_answers()
        self.assertEqual(len(errors), 1)

    def test_multi_select_invalid_option(self):
        resp = self._make_response(
            [{"id": "f1", "type": "multi_select", "label": "Tags", "required": True, "order": 0,
              "options": ["A", "B", "C"]}],
            {"f1": ["A", "Z"]}  # Z is not valid
        )
        errors = resp.validate_answers()
        self.assertEqual(len(errors), 1)

    def test_optional_field_missing_is_valid(self):
        resp = self._make_response(
            [{"id": "f1", "type": "text", "label": "Notes", "required": False, "order": 0}],
            {}
        )
        errors = resp.validate_answers()
        self.assertEqual(len(errors), 0)

    def test_all_valid(self):
        resp = self._make_response(
            [
                {"id": "f1", "type": "text", "label": "Name", "required": True, "order": 0},
                {"id": "f2", "type": "select", "label": "Result", "required": True, "order": 1,
                 "options": ["Pass", "Fail"]},
                {"id": "f3", "type": "number", "label": "Score", "required": False, "order": 2,
                 "validation": {"min": 0, "max": 10}},
            ],
            {"f1": "John Smith", "f2": "Pass", "f3": 9}
        )
        errors = resp.validate_answers()
        self.assertEqual(len(errors), 0)
