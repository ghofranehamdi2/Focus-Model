import json


class APIClient:
    """Lightweight stub APIClient used for local runs.

    Methods intentionally do not perform network I/O; they only log calls.
    """

    def __init__(self, base_url: str = "http://localhost:8000/api/v1"):
        self.base_url = base_url

    def ensure_session(self, session_id: str) -> None:
        print(f"[output.APIClient] ensure_session called for {session_id}")

    def send_snapshot(self, snapshot: dict) -> None:
        try:
            s = json.dumps(snapshot)
        except Exception:
            s = json.dumps(snapshot, default=str)
        print(f"[output.APIClient] send_snapshot called (len={len(s)} bytes)")

    def send_event(self, event: dict) -> None:
        print(f"[output.APIClient] send_event called: {event.get('event_type', 'unknown')}")

    def finalize_session(self, session_id: str, summary: dict) -> None:
        print(f"[output.APIClient] finalize_session called for {session_id}")
