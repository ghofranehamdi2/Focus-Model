#!/usr/bin/env bash
# =============================================================================
# SmartFocus — Raspberry Pi 5 Complete Setup (CV + Voice)
# =============================================================================
# Run once after cloning the repo on your Pi:
#   chmod +x setup_pi.sh
#   bash setup_pi.sh
# =============================================================================

set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
ok()   { echo -e "${GREEN}[OK]${NC}  $*"; }
info() { echo -e "${CYAN}[--]${NC}  $*"; }
warn() { echo -e "${YELLOW}[!!]${NC}  $*"; }
err()  { echo -e "${RED}[ERR]${NC} $*" >&2; }

ARCH=$(uname -m)
OS=$(uname -s)

if [[ "$OS" != "Linux" ]]; then
    err "This script is for Raspberry Pi / Linux only."
    exit 1
fi

echo -e "\n${BOLD}=====================================================${NC}"
echo -e "${BOLD}   SmartFocus Pi5 Setup${NC}"
echo -e "${BOLD}=====================================================${NC}"
info "Architecture : $ARCH"
info "OS           : $OS $(lsb_release -rs 2>/dev/null || true)"
echo ""

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VA_DIR="$SCRIPT_DIR/voice_assistant"

# ── Step 1: System packages ───────────────────────────────────────────────────
echo -e "\n${BOLD}[1/8] System packages${NC}"
sudo apt-get update -qq
sudo apt-get install -y \
    python3-dev python3-pip python3-venv \
    cmake libatlas-base-dev \
    ffmpeg portaudio19-dev libsndfile1 libsndfile1-dev \
    libasound2-dev espeak-ng \
    libcap-dev curl wget unzip tar \
    libgl1 libglib2.0-0
ok "System packages installed."

# ── Step 2: Python venv ───────────────────────────────────────────────────────
echo -e "\n${BOLD}[2/8] Python virtual environment${NC}"
if [[ ! -d "$SCRIPT_DIR/.venv" ]]; then
    python3 -m venv "$SCRIPT_DIR/.venv"
    ok "venv created at .venv"
else
    warn ".venv already exists — skipping creation."
fi
source "$SCRIPT_DIR/.venv/bin/activate"
pip install --upgrade pip --quiet
ok "pip upgraded."

# ── Step 3: PyTorch CPU (ARM64) ───────────────────────────────────────────────
echo -e "\n${BOLD}[3/8] PyTorch CPU (ARM64)${NC}"
if python3 -c "import torch" 2>/dev/null; then
    warn "PyTorch already installed — skipping."
else
    info "Installing PyTorch CPU wheel for ARM64 (this may take a while)..."
    pip install torch torchvision --index-url https://download.pytorch.org/whl/cpu --quiet
    ok "PyTorch installed."
fi

# ── Step 4: CV dependencies ───────────────────────────────────────────────────
echo -e "\n${BOLD}[4/8] CV dependencies${NC}"
pip install -r "$SCRIPT_DIR/requirements_pi.txt" --quiet
ok "CV dependencies installed."

# ── Step 5: Voice dependencies ────────────────────────────────────────────────
echo -e "\n${BOLD}[5/8] Voice dependencies${NC}"
pip install pyaudio --quiet || warn "pyaudio install failed — continuing anyway."
pip install -r "$SCRIPT_DIR/requirements_pi_voice.txt" --quiet
ok "Voice dependencies installed."

# tflite-runtime is listed in requirements_pi.txt but pip may need a specific wheel on Pi
if ! python3 -c "import tflite_runtime" 2>/dev/null; then
    info "tflite-runtime not found via pip, trying apt fallback..."
    sudo apt-get install -y python3-tflite-runtime 2>/dev/null || \
        pip install --extra-index-url https://google-coral.github.io/py-repo/ tflite_runtime --quiet || \
        warn "tflite-runtime install failed — phone detection will be disabled on Pi."
fi

# ── Step 6: Piper TTS binary ──────────────────────────────────────────────────
echo -e "\n${BOLD}[6/8] Piper TTS binary${NC}"
PIPER_BIN_DIR="$VA_DIR/piper_bin"
PIPER_BINARY="$PIPER_BIN_DIR/piper"
mkdir -p "$PIPER_BIN_DIR"

if [[ -f "$PIPER_BINARY" ]]; then
    warn "Piper binary already exists — skipping."
else
    if [[ "$ARCH" == "aarch64" ]] || [[ "$ARCH" == "arm64" ]]; then
        PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_aarch64.tar.gz"
    else
        PIPER_URL="https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_linux_x86_64.tar.gz"
    fi
    info "Downloading Piper from $PIPER_URL ..."
    TMP=$(mktemp --suffix=".tar.gz")
    curl -L --progress-bar "$PIPER_URL" -o "$TMP"
    tar -xzf "$TMP" -C "$PIPER_BIN_DIR" --strip-components=1
    rm -f "$TMP"
    chmod +x "$PIPER_BINARY"
    ok "Piper binary ready."
fi

# ── Step 7: Piper French voice model ─────────────────────────────────────────
echo -e "\n${BOLD}[7/8] Piper French voice model${NC}"
MODELS_DIR="$VA_DIR/piper_models"
VOICE_MODEL="fr_FR-upmc-medium"
mkdir -p "$MODELS_DIR"
HF_BASE="https://huggingface.co/rhasspy/piper-voices/resolve/main/fr/fr_FR/upmc/medium"

for EXT in onnx "onnx.json"; do
    FILE="$MODELS_DIR/${VOICE_MODEL}.${EXT}"
    if [[ -f "$FILE" ]]; then
        warn "${VOICE_MODEL}.${EXT} already exists — skipping."
    else
        info "Downloading ${VOICE_MODEL}.${EXT} ..."
        curl -L --progress-bar "$HF_BASE/${VOICE_MODEL}.${EXT}" -o "$FILE"
        ok "$(basename "$FILE") ready."
    fi
done

# ── Step 8: Whisper + OpenWakeWord pre-download ───────────────────────────────
echo -e "\n${BOLD}[8/8] Pre-downloading ML models${NC}"

python3 -c "
import whisper
print('  Loading Whisper tiny...')
whisper.load_model('tiny')
print('  Whisper tiny ready.')
" && ok "Whisper tiny ready." || warn "Whisper pre-load failed — will retry on first run."

python3 -c "
from openwakeword.utils import download_models
print('  Downloading hey_jarvis...')
download_models(model_names=['hey_jarvis'])
print('  hey_jarvis ready.')
" && ok "OpenWakeWord hey_jarvis ready." || warn "OWW pre-download failed — will retry on first run."

# ── Summary ───────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}=====================================================${NC}"
echo -e "${GREEN}${BOLD}   Setup complete!${NC}"
echo -e "${BOLD}=====================================================${NC}"
echo ""
echo "  Start SmartFocus:"
echo "    bash launch_pi.sh"
echo ""
echo "  Or individually:"
echo "    Terminal 1:  python main_cv.py"
echo "    Terminal 2:  python run_voice_assistant.py"
echo ""
echo "  USB webcam:     python main_cv.py --camera 0"
echo "  Pi Camera:      python main_cv.py --camera 0   (via /dev/video0 with libcamera)"
echo "  With UI (HDMI): DISPLAY=:0 python main_cv.py"
echo ""
