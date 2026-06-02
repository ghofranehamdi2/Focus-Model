#!/usr/bin/env bash
# =============================================================================
# SmartFocus — Pi5 Launcher
# Starts CV pipeline + Voice Assistant in parallel (tmux or background)
# =============================================================================
# Usage:
#   bash launch_pi.sh              # background jobs
#   bash launch_pi.sh --tmux       # split tmux panes (recommended for Pi)
# =============================================================================

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PYTHON="$SCRIPT_DIR/.venv/bin/python3"
if [[ ! -f "$PYTHON" ]]; then PYTHON="python3"; fi

USE_TMUX=false
if [[ "${1:-}" == "--tmux" ]]; then USE_TMUX=true; fi

if $USE_TMUX; then
    if ! command -v tmux &>/dev/null; then
        echo "[WARN] tmux not found. Install with: sudo apt install tmux"
        echo "       Falling back to background jobs."
        USE_TMUX=false
    fi
fi

cd "$SCRIPT_DIR"

# Kill any leftover processes from a previous run before starting fresh
pkill -f main_cv.py 2>/dev/null || true
pkill -f run_voice_assistant.py 2>/dev/null || true

if $USE_TMUX; then
    # ── tmux: two panes side by side ─────────────────────────────────────────
    SESSION="smartfocus"
    tmux new-session -d -s "$SESSION" -x 220 -y 50 2>/dev/null || tmux kill-session -t "$SESSION" && tmux new-session -d -s "$SESSION" -x 220 -y 50
    tmux rename-window -t "$SESSION:0" "SmartFocus"
    tmux send-keys -t "$SESSION:0" "cd '$SCRIPT_DIR' && '$PYTHON' main_cv.py" Enter
    tmux split-window -t "$SESSION:0" -h
    sleep 5
    tmux send-keys -t "$SESSION:0.1" "cd '$SCRIPT_DIR' && '$PYTHON' run_voice_assistant.py" Enter
    echo "[SmartFocus] Launched in tmux session '$SESSION'."
    echo "  Attach with:  tmux attach -t $SESSION"
    echo "  Detach with:  Ctrl-B then D"
    tmux attach -t "$SESSION"
else
    # ── Background jobs ───────────────────────────────────────────────────────
    SESSIONS_DIR="$SCRIPT_DIR/output/sessions"
    mkdir -p "$SESSIONS_DIR"
    # Snapshot files that already exist BEFORE this run, so we don't mistake them for the new session
    EXISTING_SESSIONS=$(ls "$SESSIONS_DIR"/*.jsonl 2>/dev/null | grep -v "_summary" | sort || true)

    echo "[1] Starting CV pipeline..."
    "$PYTHON" main_cv.py &
    CV_PID=$!
    echo "    CV pipeline PID: $CV_PID"

    echo "    Waiting for NEW session file..."
    TIMEOUT=60; ELAPSED=0; SESSION_ID=""
    while [[ $ELAPSED -lt $TIMEOUT ]]; do
        LATEST=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | grep -v "_summary" | head -1)
        if [[ -n "$LATEST" ]]; then
            LATEST_NAME=$(basename "$LATEST")
            # Only accept it if it was NOT in the pre-existing list
            if ! echo "$EXISTING_SESSIONS" | grep -qF "$LATEST_NAME"; then
                sleep 2  # give the file time to stabilize
                LATEST=$(ls -t "$SESSIONS_DIR"/*.jsonl 2>/dev/null | grep -v "_summary" | head -1)
                SESSION_ID=$(basename "$LATEST" .jsonl)
                echo "    New session file found: $SESSION_ID"
                break
            fi
        fi
        sleep 1; ELAPSED=$((ELAPSED + 1))
        echo "    ... ${ELAPSED}s"
    done
    if [[ -z "$SESSION_ID" ]]; then
        echo "[WARN] No new session file after ${TIMEOUT}s — voice assistant will use temp ID."
    fi

    echo "[2] Starting Voice Assistant..."
    "$PYTHON" run_voice_assistant.py --session-id "$SESSION_ID" &
    VOICE_PID=$!
    echo "    Voice assistant PID: $VOICE_PID"

    echo ""
    echo "Both processes running. Press Ctrl-C to stop both."
    trap "kill $CV_PID $VOICE_PID 2>/dev/null; pkill -f main_cv.py 2>/dev/null; pkill -f run_voice_assistant.py 2>/dev/null; echo 'Stopped.'" EXIT INT TERM
    wait
fi
