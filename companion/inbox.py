"""Watches WoW's Screenshots folder for PugLogs QR codes."""
import os
import sys
import threading
import time

import cv2
import numpy as np
from PIL import Image

import payload

IMAGE_EXTENSIONS = (".jpg", ".jpeg", ".png", ".tga")


def low_contrast_to_black_white(corner):
    """The addon's subtle style draws the code as dark grey on near-black, starting exactly at
    the top-left pixel. Read the two shades from the image itself (WoW's brightness/gamma
    settings shift them) and turn the code into plain black on white."""
    if corner.shape[0] < 40 or corner.shape[1] < 40:
        return None
    background = int(corner[1, 1])
    # The quiet zone (background shade) runs diagonally until the first dark-grey square.
    edge = 0
    while edge < min(corner.shape) - 1 and abs(int(corner[edge, edge]) - background) <= 3:
        edge += 1
    if edge < 4:
        return None
    module = int(corner[edge, edge])  # the corner marker's first dark pixel
    if abs(module - background) < 5:
        return None
    closer_to_module = np.abs(corner.astype(np.int16) - module) < np.abs(corner.astype(np.int16) - background)
    return np.where(closer_to_module, 0, 255).astype(np.uint8)


def decode_file(path):
    """Returns the decoded Page, or None if the image has no PugLogs QR code."""
    with Image.open(path) as img:
        gray = np.array(img.convert("L"))
    # The addon draws a small code (2 pixels per square) in the top-left corner, either
    # black on white or low contrast. The detector misses some code sizes unless the image
    # is enlarged, so try the corner as-is, then enlarged, then the whole screenshot.
    detector = cv2.QRCodeDetectorAruco()
    h, w = gray.shape
    corner = gray[: min(h, 700), : min(w, 700)]
    subtle = low_contrast_to_black_white(corner)
    candidates = [corner]
    if subtle is not None:
        # Small codes (1 pixel per square): the detector needs them enlarged, and some code
        # sizes are only found at certain magnifications.
        candidates += [cv2.resize(subtle, None, fx=f, fy=f, interpolation=cv2.INTER_NEAREST) for f in (4, 3, 5, 6)]
    candidates += [
        cv2.resize(corner, None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST),
        cv2.resize(corner, None, fx=2, fy=2, interpolation=cv2.INTER_NEAREST),
        gray,
    ]
    for region in candidates:
        text = detector.detectAndDecode(region)[0]
        if text:
            return payload.parse(text)
    return None


STALE_AFTER = 30  # seconds: codes this much older than the newest waiting one are skipped


def _keep_awake():
    """macOS slows an app with a hidden window to a crawl (App Nap): screenshots then pile up
    for minutes and the paste box gets its answer far too late. Tell macOS we're busy.
    The Mac can still go to sleep. Returns a token that must be kept."""
    if sys.platform != "darwin":
        return None
    try:
        from Foundation import NSProcessInfo
    except ImportError:
        return None
    user_initiated_allowing_sleep = 0x00FFFFFF  # NSActivityUserInitiatedAllowingIdleSystemSleep
    return NSProcessInfo.processInfo().beginActivityWithOptions_reason_(
        user_initiated_allowing_sleep, "Reading PugLogs codes from WoW screenshots")


class Inbox:
    def __init__(self, folder, on_page, log):
        self.folder = folder
        self.on_page = on_page
        self.log = log
        self._seen = {}   # path -> modification time when handled
        self._attempts = {}  # path -> failed reads (WoW may still be writing the file)
        # For the window's connection line:
        self.last_code = None        # when a PugLogs code was last read
        self.no_code_shots = 0       # new screenshots without a PugLogs code since then

    def start(self):
        self._awake = _keep_awake()
        threading.Thread(target=self._run, daemon=True).start()

    def _files(self):
        try:
            names = os.listdir(self.folder)
        except FileNotFoundError:
            return []
        paths = [os.path.join(self.folder, n) for n in names if n.lower().endswith(IMAGE_EXTENSIONS)]

        def mtime(path):
            try:
                return os.path.getmtime(path)
            except FileNotFoundError:
                return 0

        return sorted(paths, key=mtime)  # oldest first, so the newest applicant list wins

    def _run(self):
        # Old PugLogs screenshots (e.g. taken while this program wasn't running) are
        # deleted but not used. The user's own screenshots are never touched.
        # Reading hundreds of them takes a minute, so it's done on the side: new codes (a paste
        # request) are read right away. Recent ones go through the loop below.
        started = time.time()
        old = []
        for path in self._files():
            try:
                mtime = os.path.getmtime(path)
            except FileNotFoundError:
                continue
            if mtime < started - 120:
                self._seen[path] = mtime
                old.append(path)
        threading.Thread(target=self._clear, args=(old,), daemon=True).start()
        while True:
            waiting = []
            for path in self._files():
                try:
                    mtime = os.path.getmtime(path)
                except FileNotFoundError:
                    continue
                if self._seen.get(path) != mtime:
                    waiting.append((path, mtime))
            newest = waiting[-1][1] if waiting else 0
            for path, mtime in waiting:
                self._seen[path] = mtime
                self._wait_until_written(path)
                # If we fell behind, old codes are out of date: clear them away unused, so the
                # latest applicant list and paste request are read without waiting for them.
                self._handle(path, use=mtime >= newest - STALE_AFTER)
            time.sleep(0.25)

    def _clear(self, paths):
        for path in paths:
            self._handle(path, use=False, retry=False)

    @staticmethod
    def _wait_until_written(path):
        last = -1
        for _ in range(20):
            try:
                size = os.path.getsize(path)
            except FileNotFoundError:
                return
            if size == last and size > 0:
                return
            last = size
            time.sleep(0.15)

    def _handle(self, path, use, retry=True):
        try:
            page = decode_file(path)
        except Exception as e:  # usually a screenshot WoW is still writing: try again shortly
            tries = self._attempts.get(path, 0) + 1
            self._attempts[path] = tries
            if retry and tries < 10:
                self._seen.pop(path, None)  # picked up again on the next check
            else:
                self.log(f"Could not read {os.path.basename(path)}: {e}")
            return
        self._attempts.pop(path, None)
        if page is None:
            if use:
                self.no_code_shots += 1
            return
        if use:
            self.last_code, self.no_code_shots = time.time(), 0
        try:
            os.remove(path)
        except OSError:
            pass
        if use:
            self.on_page(page)
