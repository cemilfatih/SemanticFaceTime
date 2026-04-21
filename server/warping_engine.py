"""
NanoBand Warping Engine
Ported from poc.py — all math is identical, restructured for async server use.
Thread-safe: lock covers mutable state; heavy warping runs outside the lock on copied data.

Bandwidth model
───────────────
Standard mode  → savings = 0 % (it IS the reference baseline).
NanoBand mode  → savings = 1 - (nanoband_actual / (nanoband_seconds × 30fps × 50 KB)).
Session summary uses NanoBand-only numbers so the comparison is honest.
"""
import time
import threading
from typing import Optional

import cv2
import numpy as np


class WarpingEngine:
    FRAME_KB: float = 50.0   # ~50 KB per 30-FPS JPEG frame (baseline)
    STANDARD_FPS: float = 30.0

    STABLE_INTERVAL: float = 2.0
    TALKING_INTERVAL: float = 0.8
    HEAD_MOVE_INTERVAL: float = 0.4

    TALK_THRESHOLD: float = 1.8
    HEAD_THRESHOLD: float = 5.0
    MOUTH_TRIGGER_PX: float = 8.0

    def __init__(self) -> None:
        self._lock = threading.Lock()

        self.anchor_frame: Optional[np.ndarray] = None
        self.anchor_points_ext: Optional[np.ndarray] = None
        self.tri_indices: list = []

        self.prev_landmarks: Optional[np.ndarray] = None
        self.smoothed_lms: Optional[np.ndarray] = None
        self.last_anchor_time: float = 0.0
        self.current_interval: float = self.STABLE_INTERVAL
        self.status: str = "WAITING"

        # ── Bandwidth tracking (mode-aware) ──────────────────────────
        self._session_start: float = time.time()

        # NanoBand counters
        self._nb_bytes: int = 0
        self._nb_elapsed: float = 0.0        # finalized seconds in NanoBand
        self._nb_mode_start: Optional[float] = None  # None = not in NB mode

        # Standard counters
        self._std_bytes: int = 0
        self._std_elapsed: float = 0.0
        self._std_mode_start: Optional[float] = None

        self._current_mode: str = ''          # 'nanoband' | 'standard'

    # ── Public API ───────────────────────────────────────────────────

    def add_bytes(self, n: int, mode: str) -> None:
        """Track bytes + time spent in each mode."""
        with self._lock:
            now = time.time()
            if mode != self._current_mode:
                self._finalize_mode_unlocked(now)
                self._current_mode = mode
                if mode == 'nanoband':
                    self._nb_mode_start = now
                else:
                    self._std_mode_start = now
            if mode == 'nanoband':
                self._nb_bytes += n
            else:
                self._std_bytes += n

    def set_anchor(self, frame_bytes: bytes, landmarks: list) -> None:
        arr = np.frombuffer(frame_bytes, dtype=np.uint8)
        # Resmi OpenCV standart formatında (BGR) çöz
        frame = cv2.imdecode(arr, cv2.IMREAD_COLOR)
        if frame is None or len(landmarks) < 3:
            return
        
        # DİKKAT: Buradaki cv2.cvtColor(...) satırını TAMAMEN SİLDİK!
        # Flutter'dan gelen JPEG zaten doğru renklerde, OpenCV'nin kafasını karıştırmıyoruz.
        
        lms = np.array(landmarks, dtype=np.float32)
        h, w = frame.shape[:2]
        tri_indices, anchor_pts_ext = _build_delaunay(lms, w, h)
        with self._lock:
            self.anchor_frame = frame
            self.anchor_points_ext = anchor_pts_ext
            self.tri_indices = tri_indices
            self.last_anchor_time = time.time()

    def get_summary(self) -> dict:
        with self._lock:
            now = time.time()
            self._finalize_mode_unlocked(now)
            
            # MATEMATİK DÜZELTİLDİ: Sadece NanoBand modunda "teorik" 30 FPS faturası yazılır.
            # Standard modda ne harcandıysa teori de odur (Tasarruf sağlamaz).
            nb_theoretical_mb = (self._nb_elapsed * self.STANDARD_FPS * self.FRAME_KB) / 1024.0
            std_actual_mb = self._std_bytes / 1048576.0
            nb_actual_mb = self._nb_bytes / 1048576.0
            
            total_actual_mb = nb_actual_mb + std_actual_mb
            total_theoretical_mb = nb_theoretical_mb + std_actual_mb
            
            savings = 0.0
            if total_theoretical_mb > 0:
                savings = max(0.0, (1.0 - total_actual_mb / total_theoretical_mb) * 100)

            return {
                "savingsPct": round(savings, 1),
                "savedMb": round(max(0, total_theoretical_mb - total_actual_mb), 2),
                "nanobandSeconds": round(self._nb_elapsed, 1),
                "standardSeconds": round(self._std_elapsed, 1)
            }

    def _metrics_unlocked(self, status: str, interval: float, mode: str) -> dict:
        now = time.time()
        
        nb_el = self._nb_elapsed + (now - self._nb_mode_start if self._current_mode == 'nanoband' and self._nb_mode_start else 0)
        std_el = self._std_elapsed + (now - self._std_mode_start if self._current_mode == 'standard' and self._std_mode_start else 0)

        nb_actual_mb = self._nb_bytes / 1048576.0
        std_actual_mb = self._std_bytes / 1048576.0
        
        nb_theoretical_mb = (nb_el * self.STANDARD_FPS * self.FRAME_KB) / 1024.0
        
        total_actual_mb = nb_actual_mb + std_actual_mb
        total_theoretical_mb = nb_theoretical_mb + std_actual_mb

        savings = 0.0
        if total_theoretical_mb > 0:
            savings = max(0.0, (1.0 - total_actual_mb / total_theoretical_mb) * 100)

        return {
            "status": status,
            "mode": mode,
            "actual_mb": round(total_actual_mb, 4),
            "theoretical_mb": round(total_theoretical_mb, 4),
            "savings_pct": round(savings, 1),
            "current_interval": interval,
            "current_fps": round(1.0 / interval, 1) if interval > 0 else 0
        }
    def process(
        self,
        landmarks: list,
        img_w: int,
        img_h: int,
    ) -> tuple[Optional[np.ndarray], str, bool, dict]:
        with self._lock:
            # 🎯 KESİN ÇÖZÜM: Dart'tan gelen 1-2 piksellik yuvarlama hatalarını yoksay!
            # Resmin altının kesilmesini sonsuza dek engeller.
            if self.anchor_frame is not None:
                img_h, img_w = self.anchor_frame.shape[:2]

            raw_lms = np.array(landmarks, dtype=np.float32)

            if self.smoothed_lms is None or self.smoothed_lms.shape != raw_lms.shape:
                self.smoothed_lms = raw_lms.copy()
            else:
                self.smoothed_lms = self.smoothed_lms * 0.2 + raw_lms * 0.8
            
            curr_lms = self.smoothed_lms.astype(np.int32)

            motion = _calc_motion(self.prev_landmarks, curr_lms)
            curr_mouth = _mouth_open(curr_lms)

            if motion >= self.HEAD_THRESHOLD:
                self.current_interval = self.HEAD_MOVE_INTERVAL
                self.status = "HEAD MOVING"
            elif motion >= self.TALK_THRESHOLD:
                self.current_interval = self.TALKING_INTERVAL
                self.status = "TALKING"
            else:
                self.current_interval = self.STABLE_INTERVAL
                self.status = "STABLE"

            force = False
            if self.anchor_frame is not None and self.anchor_points_ext is not None:
                anchor_mouth = _mouth_open(
                    self.anchor_points_ext[: len(landmarks)].astype(np.int32)
                )
                if abs(curr_mouth - anchor_mouth) > self.MOUTH_TRIGGER_PX:
                    force = True
                    self.status = "MOUTH TRIGGER"

            elapsed = time.time() - self.last_anchor_time
            needs_anchor = (
                self.anchor_frame is None
                or elapsed > self.current_interval
                or force
            )

            self.prev_landmarks = curr_lms.copy()
            captured_status = self.status
            captured_interval = self.current_interval

            anchor_copy = self.anchor_frame.copy() if self.anchor_frame is not None else None
            pts_copy = self.anchor_points_ext.copy() if self.anchor_points_ext is not None else None
            tri_copy = list(self.tri_indices)

        warped: Optional[np.ndarray] = None
        if anchor_copy is not None and pts_copy is not None and tri_copy:
            warped = _warp(anchor_copy, tri_copy, pts_copy, curr_lms, img_w, img_h)

        with self._lock:
            metrics = self._metrics_unlocked(captured_status, captured_interval, 'nanoband')

        return warped, captured_status, needs_anchor, metrics

    def get_standard_metrics(self) -> dict:
        with self._lock:
            return self._metrics_unlocked(self.status, self.current_interval, 'standard')



    def reset(self) -> None:
        with self._lock:
            self.anchor_frame = None
            self.anchor_points_ext = None
            self.tri_indices = []
            self.prev_landmarks = None
            self.smoothed_lms = None
            self.last_anchor_time = 0.0
            self.current_interval = self.STABLE_INTERVAL
            self.status = "WAITING"
            self._session_start = time.time()
            self._nb_bytes = 0
            self._nb_elapsed = 0.0
            self._nb_mode_start = None
            self._std_bytes = 0
            self._std_elapsed = 0.0
            self._std_mode_start = None
            self._current_mode = ''

    # ── Private ──────────────────────────────────────────────────────

    def _finalize_mode_unlocked(self, now: float) -> None:
        """Close out elapsed time for the outgoing mode."""
        if self._current_mode == 'nanoband' and self._nb_mode_start is not None:
            self._nb_elapsed += now - self._nb_mode_start
            self._nb_mode_start = None
        elif self._current_mode == 'standard' and self._std_mode_start is not None:
            self._std_elapsed += now - self._std_mode_start
            self._std_mode_start = None




# ── Pure functions ────────────────────────────────────────────────────

def _calc_motion(prev: Optional[np.ndarray], curr: np.ndarray) -> float:
    if prev is None:
        return 0.0
    return float(np.max(np.linalg.norm(curr.astype(float) - prev.astype(float), axis=1)))


def _mouth_open(lms: np.ndarray) -> float:
    if lms is None or len(lms) < 15:
        return 0.0
    return float(np.linalg.norm(lms[13].astype(float) - lms[14].astype(float)))


def _build_delaunay(landmarks: np.ndarray, w: int, h: int) -> tuple[list, np.ndarray]:
    ext_pts = np.vstack([
        landmarks,
        [[0, 0], [w - 1, 0], [0, h - 1], [w - 1, h - 1],
         [w // 2, 0], [0, h // 2], [w - 1, h // 2], [w // 2, h - 1]],
    ])
    
    # DEVASA GÜVENLİK ALANI: -211 Hatasını sonsuza dek çözer
    rect = (-5000, -5000, w + 10000, h + 10000)
    subdiv = cv2.Subdiv2D(rect)
    
    for p in ext_pts:
        # Noktaları çerçeve içine zorla (Clamping)
        px = max(-4900, min(w + 9900, float(p[0])))
        py = max(-4900, min(h + 9900, float(p[1])))
        subdiv.insert((px, py))

    tri_indices = []
    for t in subdiv.getTriangleList():
        raw_pts = [(t[0], t[1]), (t[2], t[3]), (t[4], t[5])]
        idxs = []
        for rp in raw_pts:
            d = np.linalg.norm(ext_pts - rp, axis=1)
            i = int(np.argmin(d))
            if d[i] < 1.0:
                idxs.append(i)
        if len(idxs) == 3:
            tri_indices.append(idxs)

    return tri_indices, ext_pts


def _warp(anchor, tri_indices, anchor_pts, curr_lms, img_w, img_h):
    curr_pts = np.vstack([
        curr_lms,
        [[0, 0], [img_w - 1, 0], [0, img_h - 1], [img_w - 1, img_h - 1],
         [img_w // 2, 0], [0, img_h // 2], [img_w - 1, img_h // 2], [img_w // 2, img_h - 1]],
    ])
    output = np.zeros_like(anchor)
    for tri in tri_indices:
        _warp_triangle(anchor, output, anchor_pts[tri], curr_pts[tri])
    return output


def _warp_triangle(src, dst, t1, t2):
    t1 = np.array(t1, dtype=np.int32)
    t2 = np.array(t2, dtype=np.int32)
    h, w = src.shape[:2]
    t1 = np.clip(t1, [0, 0], [w - 1, h - 1])
    t2 = np.clip(t2, [0, 0], [w - 1, h - 1])
    r1, r2 = cv2.boundingRect(t1), cv2.boundingRect(t2)
    if r1[2] <= 0 or r1[3] <= 0 or r2[2] <= 0 or r2[3] <= 0:
        return
    src_crop = src[r1[1]: r1[1] + r1[3], r1[0]: r1[0] + r1[2]]
    t1l = t1 - [r1[0], r1[1]]
    t2l = t2 - [r2[0], r2[1]]
    M = cv2.getAffineTransform(np.float32(t1l), np.float32(t2l))
    warped = cv2.warpAffine(src_crop, M, (r2[2], r2[3]),
                            flags=cv2.INTER_LINEAR, borderMode=cv2.BORDER_REFLECT_101)
    mask = np.zeros((r2[3], r2[2], 3), dtype=np.uint8)
    cv2.fillConvexPoly(mask, np.int32(t2l), (255, 255, 255))
    dst_slice = dst[r2[1]: r2[1] + r2[3], r2[0]: r2[0] + r2[2]]
    if dst_slice.shape != mask.shape:
        return
    dst[r2[1]: r2[1] + r2[3], r2[0]: r2[0] + r2[2]] = cv2.add(
        cv2.bitwise_and(warped, mask),
        cv2.bitwise_and(dst_slice, cv2.bitwise_not(mask)),
    )
