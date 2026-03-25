from django.db import migrations, models
import django.db.models.deletion


class Migration(migrations.Migration):
    """
    Adds the OneToOne FK from ChecklistResponse → Job.
    Must run after both checklists.0001 and jobs.0001 so both tables exist.
    """

    dependencies = [
        ("checklists", "0001_initial"),
        ("jobs", "0001_initial"),
    ]

    operations = [
        migrations.AddField(
            model_name="checklistresponse",
            name="job",
            field=models.OneToOneField(
                on_delete=django.db.models.deletion.CASCADE,
                related_name="checklist_response",
                to="jobs.job",
            ),
        ),
    ]
