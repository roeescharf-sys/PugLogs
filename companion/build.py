"""Builds the ready-to-run PugLogs download for this computer's system (macOS or Windows).

    pip install -r requirements.txt -r requirements-build.txt
    python build.py

Produces dist/PugLogs-<system>.zip: a PugLogs folder with the PugLogs app (PugLogs.exe on
Windows, PugLogs.app on macOS), which includes the window files and the WoW addon
(installed into WoW on first start).
"""
import os
import shutil
import subprocess
import sys

import PyInstaller.__main__

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
SYSTEM = {"win32": "Windows", "darwin": "macOS"}.get(sys.platform, sys.platform)


def main():
    def data(src, dest):
        return f"{src}{os.pathsep}{dest}"

    PyInstaller.__main__.run([
        os.path.join(HERE, "app.py"),
        "--name", "PugLogs",
        "--onedir",
        "--windowed",         # a normal app: no console window (log in ~/.config/puglogs)
        "--osx-bundle-identifier", "io.github.roeescharf-sys.puglogs",
        "--noconfirm",
        "--clean",
        "--distpath", os.path.join(HERE, "dist"),
        "--workpath", os.path.join(HERE, "build"),
        "--specpath", os.path.join(HERE, "build"),
        "--add-data", data(os.path.join(HERE, "web"), "web"),
        "--add-data", data(os.path.join(ROOT, "PugLogs"), "PugLogs"),
    ])
    dist = os.path.join(HERE, "dist")
    if sys.platform == "darwin":
        # Ship only the .app (PyInstaller also leaves a plain folder next to it).
        stage = os.path.join(HERE, "build", "stage")
        shutil.rmtree(stage, ignore_errors=True)
        os.makedirs(os.path.join(stage, "PugLogs"))
        # symlinks=True keeps the app bundle's internal links (and its signature) intact
        shutil.copytree(os.path.join(dist, "PugLogs.app"), os.path.join(stage, "PugLogs", "PugLogs.app"),
                        symlinks=True)
        root = stage
    else:
        root = dist
    shutil.copy(os.path.join(HERE, "READ ME FIRST.txt"), os.path.join(root, "PugLogs"))
    archive = os.path.join(dist, f"PugLogs-{SYSTEM}.zip")
    if os.path.exists(archive):
        os.remove(archive)
    if sys.platform == "darwin":
        # ditto keeps symlinks and permissions inside the .app (Python's zip doesn't).
        subprocess.run(["ditto", "-c", "-k", "--norsrc", "--keepParent", os.path.join(root, "PugLogs"), archive], check=True)
    else:
        shutil.make_archive(archive[:-4], "zip", root, "PugLogs")
    print("Built", archive)


if __name__ == "__main__":
    main()
