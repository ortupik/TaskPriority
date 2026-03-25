"""
Management command: seed
Generates realistic sample data for FieldPulse development.

Usage:
    python manage.py seed
    python manage.py seed --jobs 200
    python manage.py seed --flush  # clear first
"""
import random
import uuid
from datetime import timedelta

from django.core.management.base import BaseCommand
from django.utils import timezone

from apps.accounts.models import User
from apps.checklists.models import ChecklistSchema
from apps.jobs.models import Customer, Job, JobStatusHistory

FIRST_NAMES = ["James", "Maria", "David", "Sarah", "Michael", "Jennifer", "Robert", "Linda",
               "William", "Barbara", "Richard", "Susan", "Joseph", "Jessica", "Thomas", "Karen",
               "Charles", "Nancy", "Christopher", "Lisa", "Daniel", "Betty", "Matthew", "Margaret",
               "Anthony", "Sandra", "Mark", "Ashley", "Donald", "Dorothy"]

LAST_NAMES = ["Smith", "Johnson", "Williams", "Brown", "Jones", "Garcia", "Miller", "Davis",
              "Rodriguez", "Martinez", "Hernandez", "Lopez", "Gonzalez", "Wilson", "Anderson",
              "Thomas", "Taylor", "Moore", "Jackson", "Martin", "Lee", "Perez", "Thompson",
              "White", "Harris", "Sanchez", "Clark", "Ramirez", "Lewis", "Robinson"]

STREETS = ["Oak Street", "Maple Avenue", "Cedar Lane", "Pine Road", "Elm Drive",
           "Washington Blvd", "Lincoln Way", "Park Avenue", "Lake View Drive",
           "Sunset Boulevard", "Highland Ave", "Valley Road", "River Street",
           "Forest Drive", "Meadow Lane", "Spring Street", "Summer Court"]

CITIES = [
    ("Austin", "TX", "78701", 30.2672, -97.7431),
    ("Dallas", "TX", "75201", 32.7767, -96.7970),
    ("Houston", "TX", "77001", 29.7604, -95.3698),
    ("San Antonio", "TX", "78201", 29.4241, -98.4936),
    ("Denver", "CO", "80201", 39.7392, -104.9903),
    ("Phoenix", "AZ", "85001", 33.4484, -112.0740),
    ("Portland", "OR", "97201", 45.5051, -122.6750),
    ("Nashville", "TN", "37201", 36.1627, -86.7816),
    ("Charlotte", "NC", "28201", 35.2271, -80.8431),
    ("Atlanta", "GA", "30301", 33.7490, -84.3880),
]

JOB_TITLES = [
    "HVAC Annual Inspection",
    "AC Unit Repair - Refrigerant Leak",
    "Furnace Replacement",
    "Electrical Panel Upgrade",
    "Plumbing Leak Repair",
    "Water Heater Installation",
    "Roof Inspection & Assessment",
    "Gutter Cleaning & Repair",
    "Pest Control Treatment",
    "Appliance Repair - Dishwasher",
    "Appliance Repair - Washing Machine",
    "Internet/Cable Installation",
    "Security System Setup",
    "Garage Door Repair",
    "Window Seal Replacement",
    "Chimney Sweep & Inspection",
    "Deck Repair & Staining",
    "Fence Installation",
    "Irrigation System Service",
    "Pool Maintenance Visit",
    "Generator Service",
    "Fire Suppression System Inspection",
    "Elevator Annual Certification",
    "Commercial Refrigeration Service",
    "Emergency Water Extraction",
]

JOB_DESCRIPTIONS = [
    "Perform annual maintenance and inspection. Check all components for wear and proper operation.",
    "Customer reports intermittent failure. Diagnose root cause and complete repair. Test before departure.",
    "Full replacement required per previous assessment. Coordinate with customer for access.",
    "Upgrade to meet current code requirements. Verify all circuits are properly labeled.",
    "Locate and repair leak. Check for water damage. Provide remediation recommendations if needed.",
    "New installation per customer order. Include permit inspection if required by jurisdiction.",
    "Comprehensive inspection with written report. Document all findings with photographs.",
    "Routine service visit. Complete all checklist items and note any follow-up requirements.",
]


def _make_inspection_schema(created_by):
    return ChecklistSchema.objects.create(
        name="Standard Inspection Checklist",
        description="Used for routine inspection visits.",
        fields=[
            {
                "id": "f_arrival_condition",
                "type": "select",
                "label": "Site Condition on Arrival",
                "required": True,
                "order": 0,
                "options": ["Clean", "Minor Issues", "Major Issues", "Hazardous"],
                "help_text": "Overall condition when technician arrived",
            },
            {
                "id": "f_work_performed",
                "type": "textarea",
                "label": "Work Performed",
                "required": True,
                "order": 1,
                "validation": {"min_length": 20, "max_length": 2000},
                "placeholder": "Describe all work completed during this visit...",
            },
            {
                "id": "f_parts_used",
                "type": "textarea",
                "label": "Parts / Materials Used",
                "required": False,
                "order": 2,
                "validation": {"max_length": 500},
                "placeholder": "List any parts replaced or materials consumed",
            },
            {
                "id": "f_result",
                "type": "select",
                "label": "Job Result",
                "required": True,
                "order": 3,
                "options": ["Pass", "Fail", "Needs Follow-up", "Incomplete"],
            },
            {
                "id": "f_follow_up",
                "type": "checkbox",
                "label": "Follow-up Visit Required",
                "required": False,
                "order": 4,
            },
            {
                "id": "f_follow_up_notes",
                "type": "textarea",
                "label": "Follow-up Notes",
                "required": False,
                "order": 5,
                "validation": {"max_length": 500},
                "placeholder": "Describe what follow-up is needed",
            },
            {
                "id": "f_before_photo",
                "type": "photo",
                "label": "Before Photo",
                "required": True,
                "order": 6,
                "max_photos": 3,
                "help_text": "Take photos before starting work",
            },
            {
                "id": "f_after_photo",
                "type": "photo",
                "label": "After Photo",
                "required": True,
                "order": 7,
                "max_photos": 3,
                "help_text": "Take photos after completing work",
            },
            {
                "id": "f_customer_rating",
                "type": "select",
                "label": "Customer Satisfaction",
                "required": True,
                "order": 8,
                "options": ["1 - Very Dissatisfied", "2 - Dissatisfied", "3 - Neutral", "4 - Satisfied", "5 - Very Satisfied"],
            },
            {
                "id": "f_signature",
                "type": "signature",
                "label": "Customer Signature",
                "required": True,
                "order": 9,
                "help_text": "Have the customer sign to confirm work completion",
            },
        ],
        created_by=created_by,
    )


def _make_hvac_schema(created_by):
    return ChecklistSchema.objects.create(
        name="HVAC Service Checklist",
        description="Detailed checklist for HVAC maintenance and repair.",
        fields=[
            {"id": "f_unit_model", "type": "text", "label": "Unit Model Number", "required": True, "order": 0, "placeholder": "e.g. Carrier 24ACC636A003"},
            {"id": "f_unit_serial", "type": "text", "label": "Unit Serial Number", "required": True, "order": 1},
            {"id": "f_refrigerant_type", "type": "select", "label": "Refrigerant Type", "required": True, "order": 2, "options": ["R-22", "R-410A", "R-32", "R-407C", "Other"]},
            {"id": "f_refrigerant_added", "type": "number", "label": "Refrigerant Added (lbs)", "required": False, "order": 3, "validation": {"min": 0, "max": 50}},
            {"id": "f_suction_pressure", "type": "number", "label": "Suction Pressure (PSI)", "required": True, "order": 4, "validation": {"min": 0, "max": 500}},
            {"id": "f_discharge_pressure", "type": "number", "label": "Discharge Pressure (PSI)", "required": True, "order": 5, "validation": {"min": 0, "max": 500}},
            {"id": "f_supply_temp", "type": "number", "label": "Supply Air Temp (°F)", "required": True, "order": 6, "validation": {"min": -20, "max": 150}},
            {"id": "f_return_temp", "type": "number", "label": "Return Air Temp (°F)", "required": True, "order": 7, "validation": {"min": -20, "max": 150}},
            {"id": "f_filter_replaced", "type": "checkbox", "label": "Air Filter Replaced", "required": False, "order": 8},
            {"id": "f_coil_cleaned", "type": "checkbox", "label": "Evaporator Coil Cleaned", "required": False, "order": 9},
            {"id": "f_drain_cleared", "type": "checkbox", "label": "Condensate Drain Cleared", "required": False, "order": 10},
            {"id": "f_issues", "type": "multi_select", "label": "Issues Found", "required": False, "order": 11, "options": ["Refrigerant Leak", "Electrical Fault", "Compressor Noise", "Dirty Coils", "Clogged Drain", "Worn Belts", "None"]},
            {"id": "f_next_service", "type": "datetime", "label": "Recommended Next Service Date", "required": False, "order": 12},
            {"id": "f_photo", "type": "photo", "label": "Unit Photos", "required": True, "order": 13, "max_photos": 5},
            {"id": "f_signature", "type": "signature", "label": "Customer Signature", "required": True, "order": 14},
        ],
        created_by=created_by,
    )


class Command(BaseCommand):
    help = "Seed the database with realistic sample data"

    def add_arguments(self, parser):
        parser.add_argument("--jobs", type=int, default=120, help="Number of jobs to create")
        parser.add_argument("--flush", action="store_true", help="Delete existing data first")

    def handle(self, *args, **options):
        if options["flush"]:
            self.stdout.write("Flushing existing data...")
            JobStatusHistory.objects.all().delete()
            Job.objects.all().delete()
            Customer.objects.all().delete()
            ChecklistSchema.objects.all().delete()
            User.objects.filter(is_superuser=False).delete()

        self.stdout.write("Creating users...")
        admin = self._get_or_create_admin()
        techs = self._create_technicians(admin)

        self.stdout.write("Creating checklist schemas...")
        inspection_schema = _make_inspection_schema(admin)
        hvac_schema = _make_hvac_schema(admin)
        schemas = [inspection_schema, hvac_schema, None]  # None = no checklist

        self.stdout.write("Creating customers...")
        customers = self._create_customers(50)

        self.stdout.write(f"Creating {options['jobs']} jobs...")
        self._create_jobs(options["jobs"], customers, techs, schemas, admin)

        self.stdout.write(self.style.SUCCESS(
            f"\n✓ Seed complete!\n"
            f"  Admin: admin@fieldpulse.dev / admin123\n"
            f"  Technician: tech1@fieldpulse.dev / techie123\n"
            f"  Jobs: {options['jobs']}\n"
            f"  Customers: 50\n"
        ))

    def _get_or_create_admin(self):
        user, _ = User.objects.get_or_create(
            email="admin@fieldpulse.dev",
            defaults={
                "first_name": "Alex",
                "last_name": "Admin",
                "role": User.Role.ADMIN,
                "is_staff": True,
                "is_superuser": True,
            },
        )
        user.set_password("admin123")
        user.save()
        return user

    def _create_technicians(self, admin):
        techs = []
        tech_data = [
            ("tech1@fieldpulse.dev", "Jordany", "Rivera"),
            ("tech2@fieldpulse.dev", "Sam", "Chen"),
            ("tech3@fieldpulse.dev", "Taylor", "Okonkwo"),
            ("tech4@fieldpulse.dev", "Morgan", "Patel"),
        ]
        for email, first, last in tech_data:
            user, _ = User.objects.get_or_create(
                email=email,
                defaults={"first_name": first, "last_name": last, "role": User.Role.TECHNICIAN},
            )
            user.set_password("techie123")
            user.save()
            techs.append(user)
        return techs

    def _create_customers(self, count):
        customers = []
        for _ in range(count):
            city_data = random.choice(CITIES)
            city, state, zip_code, base_lat, base_lng = city_data
            # Jitter coordinates within ~10km
            lat = base_lat + random.uniform(-0.05, 0.05)
            lng = base_lng + random.uniform(-0.05, 0.05)

            first = random.choice(FIRST_NAMES)
            last = random.choice(LAST_NAMES)
            street_num = random.randint(100, 9999)
            street = random.choice(STREETS)

            c = Customer.objects.create(
                name=f"{first} {last}",
                email=f"{first.lower()}.{last.lower()}@example.com",
                phone=f"+1-{random.randint(200,999)}-{random.randint(200,999)}-{random.randint(1000,9999)}",
                address_line1=f"{street_num} {street}",
                city=city,
                state=state,
                zip_code=zip_code,
                country="US",
                latitude=round(lat, 7),
                longitude=round(lng, 7),
            )
            customers.append(c)
        return customers

    def _create_jobs(self, count, customers, techs, schemas, admin):
        now = timezone.now()
        statuses = ["pending"] * 40 + ["in_progress"] * 20 + ["completed"] * 30 + ["on_hold"] * 5 + ["cancelled"] * 5
        priorities = ["low"] * 10 + ["normal"] * 60 + ["high"] * 25 + ["urgent"] * 5

        for i in range(count):
            # Spread jobs across -7 days to +14 days from now
            offset_hours = random.randint(-7 * 24, 14 * 24)
            start = now + timedelta(hours=offset_hours)
            duration_hours = random.choice([1, 2, 2, 3, 4, 6])
            end = start + timedelta(hours=duration_hours)

            job_status = random.choice(statuses)
            schema = random.choice(schemas)

            job = Job(
                customer=random.choice(customers),
                assigned_to=random.choice(techs),
                created_by=admin,
                title=random.choice(JOB_TITLES),
                description=random.choice(JOB_DESCRIPTIONS),
                notes="Dispatched via FieldPulse." if random.random() > 0.5 else "",
                status=job_status,
                priority=random.choice(priorities),
                scheduled_start=start,
                scheduled_end=end,
                checklist_schema=schema,
            )

            if job_status in ("in_progress", "completed"):
                job.actual_start = start + timedelta(minutes=random.randint(0, 30))
            if job_status == "completed":
                job.actual_end = end - timedelta(minutes=random.randint(0, 30))

            # Set job_number before save to skip auto-generation jitter
            job.job_number = f"JOB-{100000 + i}"
            # Bypass the auto-increment in save() for seeding
            Job.objects.bulk_create([job])

        # Add status history for completed jobs
        for job in Job.objects.filter(status="completed")[:30]:
            JobStatusHistory.objects.create(
                job=job,
                from_status="pending",
                to_status="in_progress",
                changed_by=job.assigned_to,
            )
            JobStatusHistory.objects.create(
                job=job,
                from_status="in_progress",
                to_status="completed",
                changed_by=job.assigned_to,
                notes="All checklist items completed.",
            )
