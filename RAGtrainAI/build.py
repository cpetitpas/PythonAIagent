import subprocess
import os
import shutil

PYINSTALLER = "pyinstaller"
ISCC = r"C:\Program Files (x86)\Inno Setup 6\ISCC.exe"

def run(cmd):
    print(f"👉 Running: {cmd}")
    subprocess.run(cmd, check=True, shell=True)

def clean():
    shutil.rmtree("build", ignore_errors=True)
    shutil.rmtree("dist", ignore_errors=True)
    for f in os.listdir("."):
        if f.endswith(".spec"):
            os.remove(f)

def build_backend():
    run(f'{PYINSTALLER} --onefile --add-data "frontend;frontend" --add-data "qdrant_storage;qdrant_storage" --windowed main.py -n pai_backend.exe')

def build_app():
    run(f'{PYINSTALLER} --noconsole --onefile app.py')

def build_installer():
    run(f'"{ISCC}" pai_installer.iss')

if __name__ == "__main__":
    clean()
    build_backend()
    build_app()
    build_installer()
    print("✅ Build complete!")
