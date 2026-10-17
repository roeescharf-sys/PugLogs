"""Watches WoW's Screenshots folder for PugLogs QR codes."""
import os
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
    module = int(corner[edge + 1, edge + 1])
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
        candidates.append(cv2.resize(subtle, None, fx=3, fy=3, interpolation=cv2.INTER_NEAREST))
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


class Inbox:
    def __init__(self, folder, on_page, log):
        self.folder = folder
        self.on_page = on_page
        self.log = log
        self._seen = {}   # path -> modification time when handled

    def start(self):
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
        started = time.time()
        for path in self._files():
            self._seen[path] = os.path.getmtime(path)
            if self._seen[path] < started - 120:
                self._handle(path, use=False)
            else:
                self._handle(path, use=True)
        while True:
            for path in self._files():
                try:
                    mtime = os.path.getmtime(path)
                except FileNotFoundError:
                    continue
                if self._seen.get(path) != mtime:
                    self._seen[path] = mtime
                    self._wait_until_written(path)
                    self._handle(path, use=True)
            time.sleep(0.25)

    @staticmethod
    def _wait_until_written(path):
        last = -1
        for _ in range(20):
            size = os.path.getsize(path)
            if size == last and size > 0:
                return
            last = size
            time.sleep(0.15)

    def _handle(self, path, use):
        try:
            page = decode_file(path)
        except Exception as e:  # unreadable or half-written image
            self.log(f"Could not read {os.path.basename(path)}: {e}")
            return
        if page is None:
            return
        try:
            os.remove(path)
        except OSError:
            pass
        if use:
            self.on_page(page)
