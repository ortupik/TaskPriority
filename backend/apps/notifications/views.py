from rest_framework.decorators import api_view, permission_classes
from rest_framework.permissions import IsAuthenticated
from rest_framework.response import Response


@api_view(["POST"])
@permission_classes([IsAuthenticated])
def test_push(request):
    """Dev-only endpoint to test push notifications."""
    from .service import send_push
    send_push(
        token=request.user.fcm_token,
        title="Test Notification",
        body="FieldPulse push notifications are working!",
        data={"type": "test"},
    )
    return Response({"message": "Push sent (if FCM token registered)."})
