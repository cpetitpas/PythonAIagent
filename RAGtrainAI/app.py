import webview
import threading
import subprocess
import time
import requests
import queue
import sys
import os
import atexit
import zipfile
import tempfile
from pathlib import Path
import smtplib
from email.message import EmailMessage

def bundled_exe(name: str) -> Path:
    """
    Resolve path to a bundled exe. Works in dev and onedir builds.
    """
    if getattr(sys, "frozen", False):  # PyInstaller
        base_path = Path(sys.executable).parent.parent  # move up to installDir
    else:
        base_path = Path(__file__).parent.parent  # move up to project root
    path = base_path / name
    if not path.exists():
        raise FileNotFoundError(f"Bundled exe not found: {path}")
    return path

BACKEND_EXE = bundled_exe(Path("pai_backend") / "pai_backend.exe")

backend_queue = queue.Queue()
backend_ready = [False]
backend_process = None
qdrant_process = None

# Logging
LOG_DIR = os.path.join(os.getenv("LOCALAPPDATA", "."), "paiassistant", "logs")
os.makedirs(LOG_DIR, exist_ok=True)
LOG_FILE = os.path.join(LOG_DIR, "pai_log.txt")

# Where to store qdrant.exe after download
QDRANT_DIR = Path(os.getenv("LOCALAPPDATA", str(Path.home()))) / "paiassistant" / "qdrant"
QDRANT_EXE = QDRANT_DIR / "qdrant.exe"
QDRANT_URL = "http://127.0.0.1:6333"
QDRANT_DOWNLOAD = "https://github.com/qdrant/qdrant/releases/download/v1.15.4/qdrant-x86_64-pc-windows-msvc.zip"



# =========================
# Qdrant management
# =========================
def ensure_qdrant(window=None):
    """Download and extract Qdrant.exe if not already present."""
    if QDRANT_EXE.exists():
        if window:
            window.evaluate_js("document.getElementById('status').innerText = 'Qdrant already installed.';")
        return

    if window:
        window.evaluate_js("document.getElementById('status').innerText = 'Qdrant not found, downloading...';")

    QDRANT_DIR.mkdir(parents=True, exist_ok=True)
    tmp_zip = Path(tempfile.gettempdir()) / "qdrant.zip"

    import urllib.request

    def reporthook(blocknum, blocksize, totalsize):
        if window:
            percent = int(blocknum * blocksize * 100 / totalsize)
            window.evaluate_js(f"document.getElementById('status').innerText = 'Downloading Qdrant... {percent}%';")

    urllib.request.urlretrieve(QDRANT_DOWNLOAD, tmp_zip, reporthook)

    if window:
        window.evaluate_js("document.getElementById('status').innerText = 'Extracting Qdrant...';")

    with zipfile.ZipFile(tmp_zip, "r") as zip_ref:
        for member in zip_ref.namelist():
            if member.endswith("qdrant.exe"):
                zip_ref.extract(member, QDRANT_DIR)
                extracted_path = QDRANT_DIR / member
                extracted_path.rename(QDRANT_EXE)
                break

    if window:
        window.evaluate_js("document.getElementById('status').innerText = 'Qdrant installed successfully.';")

def start_qdrant(window=None):
    """Start Qdrant server."""
    global qdrant_process
    ensure_qdrant(window)

    if window:
        window.evaluate_js("document.getElementById('status').innerText = 'Starting Qdrant...';")

    qdrant_process = subprocess.Popen(
        [str(QDRANT_EXE)],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.STDOUT,
        creationflags=subprocess.CREATE_NO_WINDOW
    )

    start_time = time.time()
    while True:
        try:
            requests.get(QDRANT_URL)
            if window:
                window.evaluate_js("document.getElementById('status').innerText = 'Qdrant is ready.';")
            return
        except Exception:
            if time.time() - start_time > 20:
                raise RuntimeError("Qdrant failed to start in 20s")
            time.sleep(0.5)

def kill_qdrant():
    """Kill Qdrant process if running."""
    global qdrant_process
    if qdrant_process and qdrant_process.poll() is None:
        try:
            qdrant_process.terminate()
            qdrant_process.wait(timeout=3)
        except Exception:
            subprocess.call(
                ["taskkill", "/F", "/T", "/PID", str(qdrant_process.pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
    qdrant_process = None

# =========================
# Backend management
# =========================
def start_backend():
    global backend_process

    try:
        backend_process = subprocess.Popen(
            [str(BACKEND_EXE)],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            creationflags=subprocess.CREATE_NO_WINDOW
        )
    except Exception as e:
        with open(LOG_FILE, "w", encoding="utf-8") as f:
            f.write(f"Failed to start backend: {e}\n")
        raise

    # Stream logs in background
    def reader():
        with open(LOG_FILE, "a", encoding="utf-8") as log_file:
            for line in backend_process.stdout:
                backend_queue.put(line)
                log_file.write(line)
                log_file.flush()

    threading.Thread(target=reader, daemon=True).start()


def wait_for_backend(url="http://127.0.0.1:8000", timeout=30):
    """Poll until backend responds or timeout."""
    start_time = time.time()
    while True:
        try:
            requests.get(url)
            return True
        except requests.exceptions.ConnectionError:
            if time.time() - start_time > timeout:
                return False
            time.sleep(0.5)

def kill_backend():
    """Kill backend process."""
    global backend_process
    if backend_process and backend_process.poll() is None:
        try:
            backend_process.terminate()
            backend_process.wait(timeout=3)
        except Exception:
            subprocess.call(
                ["taskkill", "/F", "/T", "/PID", str(backend_process.pid)],
                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
            )
    backend_process = None

# =========================
# PyWebView API
# =========================
class API:
    def save_log(self):
        """Save log file to user's Downloads."""
        if not os.path.exists(LOG_FILE):
            return {"error": "Log file not found."}
        downloads = os.path.join(os.path.expanduser("~"), "Downloads")
        dest_path = os.path.join(downloads, f"pai_log.txt")
        try:
            with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as src:
                with open(dest_path, "w", encoding="utf-8") as dst:
                    dst.write(src.read())
            return {"status": "success", "path": dest_path}
        except Exception as e:
            return {"error": str(e)}

    def send_log_email(self, recipient="chris070411@gmail.com"):
        """Send log via email using local SMTP (requires working SMTP server)."""
        if not os.path.exists(LOG_FILE):
            return {"error": "Log file not found."}
        try:
            with open(LOG_FILE, "r", encoding="utf-8", errors="ignore") as f:
                log_text = f.read()[-5000:]  # last 5000 chars

            msg = EmailMessage()
            msg['Subject'] = "PAI Troubleshooting Log"
            msg['From'] = "paiassistant@example.com"
            msg['To'] = recipient
            msg.set_content(f"Hello Chris,\n\nHere is my troubleshooting log for PAI:\n\n{log_text}\n\nThanks!")

            with smtplib.SMTP('localhost') as s:
                s.send_message(msg)

            return {"status": "success", "recipient": recipient}

        except Exception as e:
            return {"error": str(e)}

# =========================
# GUI
# =========================
def gui():
    html = """
    <html>
    <body style="font-family:sans-serif; padding:50px; text-align:center;">
        <h2 id="status">Loading PAI Assistant...</h2>
        <p>Please wait while the backend initializes.</p>
    </body>
    </html>
    """

    api = API()
    window = webview.create_window("PAI Assistant", html=html, width=500, height=200, js_api=api)

    # Start Qdrant in a separate thread
    def start_qdrant_with_status():
        window.evaluate_js("document.getElementById('status').innerText = 'Starting Qdrant...'")
        start_qdrant(window)

    threading.Thread(target=start_qdrant_with_status, daemon=True).start()
    
    # Start backend in a separate thread
    def start_backend_with_status():
        window.evaluate_js("document.getElementById('status').innerText = 'Starting backend...'")
        start_backend()
    
    threading.Thread(target=start_backend_with_status, daemon=True).start()

    # Function to wait for backend and load correct page
    def update_loop():
        window.evaluate_js("document.getElementById('status').innerText = 'Waiting for backend...'")
        if wait_for_backend():
            backend_ready[0] = True

            # Check if OpenAI API key exists
            if not os.getenv("OPENAI_API_KEY"):
                window.evaluate_js("document.getElementById('status').innerText = 'OPENAI_API_KEY not found. Redirecting to workflow...'")
                window.load_url("http://127.0.0.1:8000/workflow.html")
            else:
                window.evaluate_js("document.getElementById('status').innerText = 'Backend ready. Loading app...'")
                window.load_url("http://127.0.0.1:8000/index.html")

            window.resize(1024, 768)
        else:
            window.evaluate_js("document.getElementById('status').innerText = 'Backend failed to start.'")
            window.load_html("<h2>Backend failed to start.</h2>")

    # Function to handle window closing
    def on_window_closed():
        try:
            requests.post("http://127.0.0.1:8000/shutdown", timeout=3)
            time.sleep(1)
        except Exception:
            pass
        finally:
            kill_backend()
            kill_qdrant()

    window.events.closed += on_window_closed
    threading.Thread(target=update_loop, daemon=True).start()
    webview.start(debug=False)


# =========================
# Ensure cleanup
# =========================
atexit.register(kill_backend)
atexit.register(kill_qdrant)

# =========================
# Launch stack
# =========================
gui()
