"""
NanoBand FastAPI Server
- /ws/mobile  → receives landmarks / anchor frames from the Flutter app
- /ws/web     → pushes reconstructed frames + metrics to the dashboard
- /           → serves the HTML dashboard
"""
import asyncio
import base64
import json
import logging
import os
from concurrent.futures import ThreadPoolExecutor
from typing import Optional

import cv2
import numpy as np
from fastapi import FastAPI, WebSocket, WebSocketDisconnect
from fastapi.responses import HTMLResponse
from fastapi.staticfiles import StaticFiles

from warping_engine import WarpingEngine

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s  [%(levelname)s]  %(message)s",
)
log = logging.getLogger("nanoband")

app = FastAPI(title="NanoBand Server", version="1.0.0")
app.mount("/static", StaticFiles(directory="static"), name="static")

engine = WarpingEngine()
_executor = ThreadPoolExecutor(max_workers=2, thread_name_prefix="warp")

# At most one warping operation at a time — newer frames skip if busy
_warp_lock = asyncio.Lock()

mobile_ws: Optional[WebSocket] = None
_web_clients: set[WebSocket] = set()


# ── helpers ───────────────────────────────────────────────────────────

async def _broadcast(payload: dict) -> None:
    if not _web_clients:
        return
    data = json.dumps(payload)
    dead: set[WebSocket] = set()
    for ws in list(_web_clients):
        try:
            await ws.send_text(data)
        except Exception:
            dead.add(ws)
    _web_clients.difference_update(dead)


def _encode_frame(frame: np.ndarray, max_width: int = 640, quality: int = 75) -> str:
    h, w = frame.shape[:2]
    if w > max_width:
        frame = cv2.resize(frame, (max_width, int(h * max_width / w)))
    _, buf = cv2.imencode(".jpg", frame, [cv2.IMWRITE_JPEG_QUALITY, quality])
    return base64.b64encode(buf).decode()


# ── routes ────────────────────────────────────────────────────────────

@app.get("/")
async def dashboard() -> HTMLResponse:
    path = os.path.join(os.path.dirname(__file__), "static", "index.html")
    with open(path, encoding="utf-8") as f:
        return HTMLResponse(f.read())


@app.websocket("/ws/mobile")
async def mobile_endpoint(ws: WebSocket) -> None:
    global mobile_ws
    await ws.accept()
    mobile_ws = ws
    engine.reset()
    log.info("Mobile connected.")
    await _broadcast({"type": "mobile_connected"})

    try:
        async for raw in ws.iter_text():
            msg = json.loads(raw)
            kind = msg.get("type")
            # Mode-aware byte tracking: standard_frame = baseline, everything else = nanoband
            mode = 'standard' if kind == 'standard_frame' else 'nanoband'
            engine.add_bytes(len(raw.encode()), mode)

            # ── Anchor frame received ──────────────────────────────
            if kind == "anchor_frame":
                frame_bytes = base64.b64decode(msg["data"])
                lms = msg.get("landmarks", [])
                loop = asyncio.get_event_loop()
                await loop.run_in_executor(_executor, engine.set_anchor, frame_bytes, lms)
                log.info("Anchor frame set.")
                await _broadcast({"type": "anchor_received"})

            # ── Landmark packet (NanoBand mode) ───────────────────
            elif kind == "landmarks":

                lms = msg["data"]
                img_w = msg.get("width", 640)
                img_h = msg.get("height", 480)
                loop = asyncio.get_event_loop()

                warped, status, needs_anchor, metrics = await loop.run_in_executor(
                    _executor, engine.process, lms, img_w, img_h
                )

                # Backend is the decision-maker: request anchor if needed
                if needs_anchor:
                    await ws.send_text(json.dumps({"type": "REQUEST_ANCHOR"}))

                if warped is not None:
                    b64 = await asyncio.get_event_loop().run_in_executor(
                        _executor, _encode_frame, warped
                    )
                    await _broadcast({"type": "frame", "data": b64, "metrics": metrics})
                else:
                    await _broadcast({"type": "metrics", **metrics})

            # ── Raw video frame (Standard mode) ───────────────────
            elif kind == "standard_frame":
                metrics = engine.get_standard_metrics()
                await _broadcast({
                    "type": "standard_frame",
                    "data": msg["data"],
                    "metrics": metrics,
                })

            # ── Call ended ────────────────────────────────────────
            elif kind == "call_ended":
                summary = engine.get_summary()
                await ws.send_text(json.dumps({"type": "session_summary", "summary": summary}))
                await _broadcast({"type": "call_ended", "summary": summary})
                # Flutter'ın beklediği camelCase key ile düzelttik
                log.info("Call ended — savings: %.1f%%", summary.get("savingsPct", 0.0))

    except WebSocketDisconnect:
        log.info("Mobile disconnected.")
    finally:
        mobile_ws = None
        await _broadcast({"type": "mobile_disconnected"})


@app.websocket("/ws/web")
async def web_endpoint(ws: WebSocket) -> None:
    await ws.accept()
    _web_clients.add(ws)
    log.info("Web client connected (%d total).", len(_web_clients))
    try:
        async for _ in ws.iter_text():
            pass  # dashboard is receive-only
    except WebSocketDisconnect:
        pass
    finally:
        _web_clients.discard(ws)
        log.info("Web client disconnected (%d total).", len(_web_clients))


# ── entry point ───────────────────────────────────────────────────────

if __name__ == "__main__":
    import uvicorn
    uvicorn.run("main:app", host="0.0.0.0", port=8000, reload=False)
