"""Reads and writes clipboard text on macOS and Windows."""
import os
import subprocess
import sys

if sys.platform == "win32":
    import ctypes
    from ctypes import wintypes

    _CF_UNICODETEXT = 13
    _GMEM_MOVEABLE = 0x0002
    _user32 = ctypes.WinDLL("user32", use_last_error=True)
    _kernel32 = ctypes.WinDLL("kernel32", use_last_error=True)
    _user32.OpenClipboard.argtypes = [wintypes.HWND]
    _user32.GetClipboardData.restype = wintypes.HANDLE
    _user32.SetClipboardData.argtypes = [wintypes.UINT, wintypes.HANDLE]
    _user32.SetClipboardData.restype = wintypes.HANDLE
    _kernel32.GlobalAlloc.argtypes = [wintypes.UINT, ctypes.c_size_t]
    _kernel32.GlobalAlloc.restype = wintypes.HGLOBAL
    _kernel32.GlobalLock.argtypes = [wintypes.HGLOBAL]
    _kernel32.GlobalLock.restype = wintypes.LPVOID
    _kernel32.GlobalUnlock.argtypes = [wintypes.HGLOBAL]

    def _open():
        # Another program may hold the clipboard for a moment; retry briefly.
        for _ in range(20):
            if _user32.OpenClipboard(None):
                return
            ctypes.windll.kernel32.Sleep(25)
        raise OSError("Could not open the clipboard")

    def copy(text):
        data = (text + "\0").encode("utf-16-le")
        _open()
        try:
            _user32.EmptyClipboard()
            handle = _kernel32.GlobalAlloc(_GMEM_MOVEABLE, len(data))
            pointer = _kernel32.GlobalLock(handle)
            ctypes.memmove(pointer, data, len(data))
            _kernel32.GlobalUnlock(handle)
            if not _user32.SetClipboardData(_CF_UNICODETEXT, handle):
                raise OSError("Could not set the clipboard")
        finally:
            _user32.CloseClipboard()

    def paste():
        _open()
        try:
            handle = _user32.GetClipboardData(_CF_UNICODETEXT)
            if not handle:
                return ""
            pointer = _kernel32.GlobalLock(handle)
            try:
                return ctypes.wstring_at(pointer)
            finally:
                _kernel32.GlobalUnlock(handle)
        finally:
            _user32.CloseClipboard()

else:
    # pbcopy/pbpaste use the locale's encoding; force UTF-8 so names like "Ánd" survive.
    _ENV = dict(os.environ, LANG="en_US.UTF-8", LC_CTYPE="en_US.UTF-8")

    def copy(text):
        subprocess.run(["pbcopy"], input=text.encode("utf-8"), check=True, env=_ENV)

    def paste():
        out = subprocess.run(["pbpaste"], capture_output=True, check=True, env=_ENV).stdout
        return out.decode("utf-8", "replace")
