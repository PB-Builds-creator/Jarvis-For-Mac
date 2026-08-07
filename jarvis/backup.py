from __future__ import annotations

import json
import secrets
import sqlite3
import subprocess
import tempfile
import zipfile
from datetime import datetime, timezone
from pathlib import Path

from .config import CONFIG_PATH, DATA_DIR, PRIVATE_FILE_MODE, ensure_dirs
from .memory import connect, record_timeline
from .privacy import get_keychain_secret, keychain_status, set_keychain_secret


BACKUP_KEY_NAME = "backup-key-v2"


def _backup_key() -> str:
    value = get_keychain_secret(BACKUP_KEY_NAME)
    if value:
        return value
    value = secrets.token_urlsafe(48)
    set_keychain_secret(BACKUP_KEY_NAME, value)
    return value


def _openssl(
    arguments: list[str],
    *,
    password: str,
    timeout: int = 120,
) -> None:
    result = subprocess.run(
        ["/usr/bin/openssl", *arguments, "-pass", "stdin"],
        input=password + "\n",
        text=True,
        capture_output=True,
        timeout=timeout,
        check=False,
    )
    if result.returncode != 0:
        raise RuntimeError(result.stderr.strip() or "Encrypted backup operation failed.")


def create_encrypted_backup(destination: Path | None = None) -> Path:
    """Create a consistent AES-256 encrypted local backup; the key stays in Keychain."""
    ensure_dirs()
    timestamp = datetime.now().strftime("%Y%m%d-%H%M%S")
    target = (
        destination.expanduser().resolve()
        if destination
        else DATA_DIR / "backups" / f"jarvis-{timestamp}.jbackup"
    )
    target.parent.mkdir(parents=True, exist_ok=True)
    if target.exists():
        raise ValueError("Backup destination already exists.")

    with tempfile.TemporaryDirectory(prefix="jarvis-backup-") as temporary:
        temporary_root = Path(temporary)
        snapshot = temporary_root / "jarvis.db"
        source = connect()
        copied = sqlite3.connect(snapshot)
        try:
            source.backup(copied)
        finally:
            copied.close()
            source.close()
        archive = temporary_root / "jarvis.zip"
        manifest = {
            "format": "jarvis-encrypted-backup-v1",
            "created_at": datetime.now(timezone.utc).isoformat(),
            "encryption": "AES-256-CBC PBKDF2 SHA-256",
            "contents": ["jarvis.db", "no_api_config.json"],
        }
        with zipfile.ZipFile(
            archive,
            "w",
            compression=zipfile.ZIP_DEFLATED,
            compresslevel=6,
        ) as bundle:
            bundle.write(snapshot, "jarvis.db")
            if CONFIG_PATH.is_file():
                bundle.write(CONFIG_PATH, "no_api_config.json")
            bundle.writestr("manifest.json", json.dumps(manifest, indent=2))
        _openssl(
            [
                "enc",
                "-aes-256-cbc",
                "-salt",
                "-pbkdf2",
                "-iter",
                "200000",
                "-in",
                str(archive),
                "-out",
                str(target),
            ],
            password=_backup_key(),
        )
    target.chmod(PRIVATE_FILE_MODE)
    record_timeline(
        "encrypted_backup_created",
        "Created encrypted local backup",
        {"file": target.name},
        privacy="private",
    )
    return target


def verify_encrypted_backup(path: Path) -> dict[str, object]:
    source = path.expanduser().resolve()
    if not source.is_file():
        raise ValueError("Backup file not found.")
    key = get_keychain_secret(BACKUP_KEY_NAME)
    if not key:
        raise RuntimeError("Jarvis backup key is not available in Keychain.")
    with tempfile.TemporaryDirectory(prefix="jarvis-verify-") as temporary:
        archive = Path(temporary) / "jarvis.zip"
        _openssl(
            [
                "enc",
                "-d",
                "-aes-256-cbc",
                "-pbkdf2",
                "-iter",
                "200000",
                "-in",
                str(source),
                "-out",
                str(archive),
            ],
            password=key,
        )
        with zipfile.ZipFile(archive) as bundle:
            bad = bundle.testzip()
            names = sorted(bundle.namelist())
    return {"valid": bad is None, "files": names, "file": source.name}


def backup_status() -> dict[str, object]:
    directory = DATA_DIR / "backups"
    backups = sorted(directory.glob("*.jbackup"), reverse=True) if directory.is_dir() else []
    return {
        "encrypted_backup_supported": True,
        "keychain": keychain_status(BACKUP_KEY_NAME),
        "count": len(backups),
        "latest": str(backups[0]) if backups else "",
    }
