import subprocess, numpy as np, cv2

class PiCamCapture:
    """Wrapper rpicam-vid → interface VideoCapture pour main_cv.py"""
    def __init__(self, width=640, height=480, fps=30):
        cmd = ["rpicam-vid", "-t", "0",
               "--width", str(width), "--height", str(height),
               "--framerate", str(fps), "--codec", "mjpeg", "-o", "-"]
        self._proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        self._buf = b""
        self._opened = True

    def isOpened(self): return self._opened

    def read(self):
        while True:
            self._buf += self._proc.stdout.read(4096)
            a = self._buf.find(b'\xff\xd8')
            b = self._buf.find(b'\xff\xd9')
            if a != -1 and b != -1:
                jpg = self._buf[a:b+2]
                self._buf = self._buf[b+2:]
                frame = cv2.imdecode(np.frombuffer(jpg, np.uint8), cv2.IMREAD_COLOR)
                if frame is not None:
                    return True, frame
            if not self._buf:
                return False, None

    def release(self):
        self._opened = False
        self._proc.terminate()

    def get(self, prop): return 0
    def set(self, prop, val): return False