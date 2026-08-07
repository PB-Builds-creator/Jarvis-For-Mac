from __future__ import annotations

import json
import zipfile
from datetime import datetime
from pathlib import Path

from .config import DATA_DIR, PRIVATE_FILE_MODE
from .health import health_snapshot
from .memory import list_timeline
from .privacy import redact_for_cloud


def create_diagnostics_pack() -> Path:
    destination = DATA_DIR / "backups" / (
        f"jarvis-diagnostics-{datetime.now().strftime('%Y%m%d-%H%M%S')}.zip"
    )
    destination.parent.mkdir(parents=True, exist_ok=True)
    health = json.dumps(health_snapshot(include_adapters=True), indent=2, default=str)
    timeline = json.dumps(
        list_timeline(250, include_private=False),
        indent=2,
        default=str,
    )
    with zipfile.ZipFile(
        destination,
        "w",
        compression=zipfile.ZIP_DEFLATED,
        compresslevel=6,
    ) as archive:
        archive.writestr("health.json", redact_for_cloud(health).text)
        archive.writestr("timeline.json", redact_for_cloud(timeline).text)
        logs = DATA_DIR / "logs"
        if logs.is_dir():
            for log in sorted(logs.glob("*.log")):
                try:
                    content = log.read_text(encoding="utf-8", errors="replace")
                except OSError:
                    continue
                archive.writestr(
                    f"logs/{log.name}",
                    redact_for_cloud(content[-200_000:]).text,
                )
    destination.chmod(PRIVATE_FILE_MODE)
    return destination
