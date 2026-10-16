"""Builds the ready-to-run PugLogs download for this computer's system (macOS or Windows).

    pip install -r requirements.txt -r requirements-build.txt
    python build.py

Produces dist/PugLogs-<system>.zip containing a PugLogs folder with the PugLogs program,
the live window files and the WoW addon (installed into WoW on first start).
"""
import os
import shutil
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
        "--console",          # shows the log; close the window (or Ctrl+C) to stop
        "--noconfirm",
        "--clean",
        "--distpath", os.path.join(HERE, "dist"),
        "--workpath", os.path.join(HERE, "build"),
        "--specpath", os.path.join(HERE, "build"),
        "--add-data", data(os.path.join(HERE, "web"), "web"),
        "--add-data", data(os.path.join(ROOT, "PugLogs"), "PugLogs"),
    ])
    folder = os.path.join(HERE, "dist", "PugLogs")
    shutil.copy(os.path.join(HERE, "READ ME FIRST.txt"), folder)
    archive = shutil.make_archive(os.path.join(HERE, "dist", f"PugLogs-{SYSTEM}"), "zip",
                                  os.path.join(HERE, "dist"), "PugLogs")
    print("Built", archive)


if __name__ == "__main__":
    main()
