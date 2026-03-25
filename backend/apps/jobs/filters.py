import django_filters
from django.db.models import Q
from .models import Job


class JobFilter(django_filters.FilterSet):
    status = django_filters.MultipleChoiceFilter(choices=Job.Status.choices)
    priority = django_filters.MultipleChoiceFilter(choices=Job.Priority.choices)
    date_from = django_filters.DateTimeFilter(field_name="scheduled_start", lookup_expr="gte")
    date_to = django_filters.DateTimeFilter(field_name="scheduled_end", lookup_expr="lte")
    search = django_filters.CharFilter(method="search_filter")
    overdue = django_filters.BooleanFilter(method="overdue_filter")

    class Meta:
        model = Job
        fields = ["status", "priority"]

    def search_filter(self, queryset, name, value):
        if not value:
            return queryset
        return queryset.filter(
            Q(customer__name__icontains=value)
            | Q(customer__address_line1__icontains=value)
            | Q(customer__city__icontains=value)
            | Q(job_number__icontains=value)
            | Q(title__icontains=value)
        )

    def overdue_filter(self, queryset, name, value):
        from django.utils import timezone
        now = timezone.now()
        if value:
            return queryset.filter(
                status__in=["pending", "in_progress"],
                scheduled_end__lt=now,
            )
        return queryset
