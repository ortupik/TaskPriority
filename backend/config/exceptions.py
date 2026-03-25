from rest_framework.views import exception_handler
from rest_framework.response import Response
from rest_framework import status
import logging

logger = logging.getLogger(__name__)


def custom_exception_handler(exc, context):
    """
    Consistent error response format:
    {
        "error": {
            "code": "VALIDATION_ERROR",
            "message": "Human-readable message",
            "details": {...}  # Optional field-level errors
        }
    }
    """
    response = exception_handler(exc, context)

    if response is not None:
        error_data = {
            "error": {
                "code": _get_error_code(response.status_code, exc),
                "message": _get_error_message(response.data),
                "details": _get_error_details(response.data),
            }
        }
        response.data = error_data
        return response

    # Unhandled exceptions
    logger.exception("Unhandled exception in view", exc_info=exc)
    return Response(
        {
            "error": {
                "code": "INTERNAL_SERVER_ERROR",
                "message": "An unexpected error occurred.",
                "details": None,
            }
        },
        status=status.HTTP_500_INTERNAL_SERVER_ERROR,
    )


def _get_error_code(status_code, exc):
    codes = {
        400: "VALIDATION_ERROR",
        401: "AUTHENTICATION_REQUIRED",
        403: "PERMISSION_DENIED",
        404: "NOT_FOUND",
        405: "METHOD_NOT_ALLOWED",
        429: "RATE_LIMIT_EXCEEDED",
        500: "INTERNAL_SERVER_ERROR",
    }
    # Use exc's get_codes() if available for more specificity
    if hasattr(exc, "get_codes"):
        codes_val = exc.get_codes()
        if isinstance(codes_val, str):
            return codes_val.upper()
    return codes.get(status_code, "ERROR")


def _get_error_message(data):
    if isinstance(data, dict):
        if "detail" in data:
            detail = data["detail"]
            return str(detail) if not isinstance(detail, list) else str(detail[0])
        # Field validation errors — summarize
        first_field = next(iter(data))
        first_errors = data[first_field]
        if isinstance(first_errors, list):
            return f"{first_field}: {first_errors[0]}"
        return str(first_errors)
    if isinstance(data, list):
        return str(data[0]) if data else "Validation error"
    return str(data)


def _get_error_details(data):
    if isinstance(data, dict) and "detail" not in data:
        # Field-level validation errors
        details = {}
        for field, errors in data.items():
            if isinstance(errors, list):
                details[field] = [str(e) for e in errors]
            else:
                details[field] = str(errors)
        return details if details else None
    return None


class APIError(Exception):
    """Raise structured API errors from business logic."""

    def __init__(self, code, message, status_code=400, details=None):
        self.code = code
        self.message = message
        self.status_code = status_code
        self.details = details
        super().__init__(message)
