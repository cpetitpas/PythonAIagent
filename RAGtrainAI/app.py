import webview
import threading
import subprocess
import time
import requests
import queue
import sys

backend_queue = queue.Queue()
backend_ready = [False]
backend_process = None

def start_backend():
    """Start the backend and stream stdout to the queue."""
    global backend_process
    backend_process = subprocess.Popen(
        ["pai_backend.exe"],
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        bufsize=1
    )
    for line in backend_process.stdout:
        backend_queue.put(line)

def wait_for_backend(url="http://127.0.0.1:8000", timeout=30):
    """Wait until the backend responds or timeout occurs."""
    start_time = time.time()
    while True:
        try:
            requests.get(url)
            return True
        except requests.exceptions.ConnectionError:
            if time.time() - start_time > timeout:
                return False
            time.sleep(0.5)

def gui():
    """Show startup log and switch to main window once backend is ready."""
    html = """
    <html>
    <body style="font-family:sans-serif; padding:10px;">
        <h3 id="status">Starting PAI backend...</h3>
        <pre id="log" style="background:#111; color:#0f0; padding:10px; height:300px; overflow:auto;"></pre>
        <script>
        window.updateLogs = function(status, text) {
            document.getElementById('status').innerText = status;
            document.getElementById('log').innerText = text;
        }
        </script>
    </body>
    </html>
    """
    window = webview.create_window("PAI Assistant Startup", html=html)

    def update_loop():
        buffer = ""
        while not backend_ready[0]:
            while not backend_queue.empty():
                buffer += backend_queue.get_nowait()
            window.evaluate_js(f'window.updateLogs("Starting PAI backend...", `{buffer.replace("`", "\\`")}`);')
            time.sleep(0.1)

        # Backend ready → load main frontend
        window.load_url("http://127.0.0.1:8000/index.html")

    threading.Thread(target=update_loop, daemon=True).start()
    webview.start()  # default backend, no admin needed

# Start backend in a thread
threading.Thread(target=start_backend, daemon=True).start()

# Wait for backend to be ready
if wait_for_backend():
    backend_ready[0] = True
else:
    print("Backend failed to start within 30 seconds.", file=sys.stderr)
    if backend_process:
        backend_process.terminate()
    sys.exit(1)

# Launch GUI
gui()
