"""Minimal output package to satisfy imports when running locally in dev.
These stubs avoid making network calls and provide simple formatting used by
`main_cv.py`. They are intentionally lightweight and safe for local runs.
"""

__all__ = ["APIClient", "JSONFormatter"]
