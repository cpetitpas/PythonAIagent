import subprocess
import os
import shutil
from pathlib import Path

PYINSTALLER = "pyinstaller"
ISCC = r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

# Optional: set your icons here (must be .ico files)
ICON_BACKEND = "icons/pai_backend.ico"
ICON_APP = "icons/app.ico"

# Optional: path to code signing cert (for later use)
SIGN_CERT = None  # e.g., r"C:\certs\mycert.pfx"
SIGN_PASS = None  # e.g., "mypassword"

def run(cmd):
    print(f"👉 Running: {cmd}")
    subprocess.run(cmd, check=True, shell=True)

def clean():
    print("🧹 Cleaning old build artifacts...")
    shutil.rmtree("build", ignore_errors=True)
    shutil.rmtree("dist", ignore_errors=True)
    for f in os.listdir("."):
        if f.endswith(".spec"):
            os.remove(f)

def build_backend():
    # Backend should be console app, not windowed
    cmd = f'{PYINSTALLER} --console main.py -n pai_backend'
    if os.path.exists("frontend"):
        cmd += ' --add-data "frontend;frontend"'
    if os.path.exists("qdrant_storage"):
        cmd += ' --add-data "qdrant_storage;qdrant_storage"'
    if os.path.exists(ICON_BACKEND):
        cmd += f' --icon "{ICON_BACKEND}"'
    run(cmd)


def build_app():
    # onedir build (no --onefile)
    cmd = f'{PYINSTALLER} --noconsole app.py -n pai_app'
    if os.path.exists(ICON_APP):
        cmd += f' --icon "{ICON_APP}"'
    run(cmd)

def build_installer():
    run(f'"{ISCC}" pai_installer.iss')

def sign_file(filepath):
    if not SIGN_CERT or not SIGN_PASS:
        print(f"⚠️ Skipping signing (no cert configured): {filepath}")
        return
    signtool = r"C:\Program Files (x86)\Windows Kits\10\bin\x64\signtool.exe"
    cmd = (
        f'"{signtool}" sign /f "{SIGN_CERT}" /p "{SIGN_PASS}" '
        f'/tr http://timestamp.sectigo.com /td sha256 /fd sha256 "{filepath}"'
    )
    run(cmd)

if __name__ == "__main__":
    clean()
    build_backend()
    build_app()
    build_installer()

    # Optional signing step
    sign_file("dist/pai_backend/pai_backend.exe")
    sign_file("dist/pai_app/pai_app.exe")
    sign_file("output/PAI_Installer.exe")

    print("✅ Build complete!")
