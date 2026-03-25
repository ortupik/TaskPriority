import time
from django.core.cache import cache
from django.conf import settings
from django.http import JsonResponse


class RateLimitMiddleware:
    """
    Simple sliding-window rate limiter based on IP address.
    Limit: RATE_LIMIT_PER_MINUTE requests per 60 seconds per IP.
    Auth endpoints have stricter limits (20/min) to prevent brute force.
    """

    def __init__(self, get_response):
        self.get_response = get_response

    def __call__(self, request):
        ip = self._get_client_ip(request)
        is_auth = request.path.startswith("/api/v1/auth/")

        limit = 20 if is_auth else getattr(settings, "RATE_LIMIT_PER_MINUTE", 60)
        window = 60  # seconds
        cache_key = f"rl:{ip}:{request.path if is_auth else 'global'}"

        now = time.time()
        requests = cache.get(cache_key, [])

        # Slide window — drop entries older than window
        requests = [t for t in requests if now - t < window]

        if len(requests) >= limit:
            return JsonResponse(
                {
                    "error": {
                        "code": "RATE_LIMIT_EXCEEDED",
                        "message": f"Too many requests. Limit: {limit} per minute.",
                        "details": None,
                    }
                },
                status=429,
                headers={"Retry-After": str(window)},
            )

        requests.append(now)
        cache.set(cache_key, requests, window)

        response = self.get_response(request)
        response["X-RateLimit-Limit"] = str(limit)
        response["X-RateLimit-Remaining"] = str(limit - len(requests))
        return response

    def _get_client_ip(self, request):
        x_forwarded_for = request.META.get("HTTP_X_FORWARDED_FOR")
        if x_forwarded_for:
            return x_forwarded_for.split(",")[0].strip()
        return request.META.get("REMOTE_ADDR", "unknown")
