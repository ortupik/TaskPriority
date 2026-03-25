from rest_framework.pagination import CursorPagination as BaseCursorPagination
from rest_framework.response import Response


class CursorPagination(BaseCursorPagination):
    """
    Cursor-based pagination for stable ordering with large datasets.
    Returns: { data: [...], pagination: { next_cursor, prev_cursor, has_next, has_prev } }
    """
    page_size = 20
    page_size_query_param = "page_size"
    max_page_size = 100
    ordering = "-scheduled_start"

    def get_paginated_response(self, data):
        return Response({
            "data": data,
            "pagination": {
                "next_cursor": self.get_next_link(),
                "prev_cursor": self.get_previous_link(),
                "has_next": self.get_next_link() is not None,
                "has_prev": self.get_previous_link() is not None,
                "page_size": self.page_size,
            }
        })

    def get_paginated_response_schema(self, schema):
        return {
            "type": "object",
            "properties": {
                "data": schema,
                "pagination": {
                    "type": "object",
                    "properties": {
                        "next_cursor": {"type": "string", "nullable": True},
                        "prev_cursor": {"type": "string", "nullable": True},
                        "has_next": {"type": "boolean"},
                        "has_prev": {"type": "boolean"},
                        "page_size": {"type": "integer"},
                    }
                }
            }
        }
