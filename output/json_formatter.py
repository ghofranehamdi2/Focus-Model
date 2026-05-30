import json
from typing import Any


class JSONFormatter:
    """Minimal formatter used by `main_cv.py` in local/dev runs.

    Produces simple dictionaries compatible with the places where the real
    formatter is used in the pipeline.
    """

    def format_clean_frame(self, payload: Any, scores: dict) -> dict:
        # Ensure the returned structure is JSON-serializable. If the payload
        # contains custom objects, stringify them to avoid serialization errors
        # when the pipeline writes JSON lines.
        try:
            payload_serialized = json.loads(json.dumps(payload, default=str))
        except Exception:
            payload_serialized = str(payload)
        return {"payload": payload_serialized, "scores": scores}

    def format_snapshot(self, payload: Any, scores: dict, clean_frame: dict) -> dict:
        return {"payload": getattr(payload, "__dict__", {}) or str(payload), "scores": scores, "frame": clean_frame}

    def format_event(self, *, session_id: str, event_type: str, level: str, description: str, metadata: dict | None = None) -> dict:
        return {
            "session_id": session_id,
            "event_type": event_type,
            "level": level,
            "description": description,
            "metadata": metadata or {},
        }
