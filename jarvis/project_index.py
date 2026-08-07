from __future__ import annotations

import hashlib
import os
import re
from pathlib import Path
from typing import Any, Iterable

from .config import load_config
from .memory import database, record_timeline, utc_now


TEXT_SUFFIXES = {
    ".c", ".cc", ".cpp", ".css", ".go", ".h", ".hpp", ".html", ".java",
    ".js", ".json", ".jsx", ".kt", ".md", ".m", ".mm", ".php", ".plist",
    ".py", ".rb", ".rs", ".sh", ".sql", ".swift", ".toml", ".ts", ".tsx",
    ".txt", ".xml", ".yaml", ".yml", ".zsh",
}
SKIP_DIRS = {
    ".git", ".hg", ".svn", ".venv", "node_modules", "dist", "build",
    "__pycache__", "Models", ".cache",
}
SYMBOL_RE = re.compile(
    r"(?m)^\s*(?:class|struct|enum|protocol|def|func|function|interface|type)"
    r"\s+([A-Za-z_][A-Za-z0-9_]*)"
)


def _approved_roots() -> tuple[Path, ...]:
    cfg = load_config()
    return tuple(
        Path(root).expanduser().resolve()
        for root in cfg.project_index_roots
        if Path(root).expanduser().is_dir()
    )


def _iter_files(root: Path) -> Iterable[Path]:
    for directory, names, files in os.walk(root):
        names[:] = [name for name in names if name not in SKIP_DIRS]
        base = Path(directory)
        for filename in files:
            path = base / filename
            if (
                path.suffix.casefold() in TEXT_SUFFIXES
                and not path.is_symlink()
            ):
                yield path


def _prepare_fts(conn) -> None:
    try:
        conn.executescript(
            """
            CREATE VIRTUAL TABLE IF NOT EXISTS project_documents_fts USING fts5(
                path, symbols, excerpt,
                content='project_documents',
                content_rowid='id'
            );
            CREATE TRIGGER IF NOT EXISTS project_fts_insert
            AFTER INSERT ON project_documents BEGIN
                INSERT INTO project_documents_fts(rowid, path, symbols, excerpt)
                VALUES (new.id, new.path, new.symbols, new.excerpt);
            END;
            CREATE TRIGGER IF NOT EXISTS project_fts_delete
            AFTER DELETE ON project_documents BEGIN
                INSERT INTO project_documents_fts(
                    project_documents_fts, rowid, path, symbols, excerpt
                ) VALUES ('delete', old.id, old.path, old.symbols, old.excerpt);
            END;
            CREATE TRIGGER IF NOT EXISTS project_fts_update
            AFTER UPDATE ON project_documents BEGIN
                INSERT INTO project_documents_fts(
                    project_documents_fts, rowid, path, symbols, excerpt
                ) VALUES ('delete', old.id, old.path, old.symbols, old.excerpt);
                INSERT INTO project_documents_fts(rowid, path, symbols, excerpt)
                VALUES (new.id, new.path, new.symbols, new.excerpt);
            END;
            """
        )
    except Exception:
        pass


def index_projects(*, maximum_files: int = 10_000) -> dict[str, int]:
    cfg = load_config()
    if not cfg.project_index_enabled:
        return {"indexed": 0, "unchanged": 0, "removed": 0}
    roots = _approved_roots()
    if not roots:
        raise RuntimeError("No approved project index roots are available.")
    indexed = 0
    unchanged = 0
    seen: set[str] = set()
    now = utc_now()
    with database() as conn:
        _prepare_fts(conn)
        for root in roots:
            for path in _iter_files(root):
                if len(seen) >= maximum_files:
                    break
                resolved = str(path.resolve())
                seen.add(resolved)
                try:
                    stat = path.stat()
                    if stat.st_size > 1_000_000:
                        continue
                    existing = conn.execute(
                        "SELECT modified_at FROM project_documents WHERE path = ?",
                        (resolved,),
                    ).fetchone()
                    if existing and float(existing["modified_at"]) == stat.st_mtime:
                        unchanged += 1
                        continue
                    raw = path.read_bytes()
                    if b"\x00" in raw[:8_192]:
                        continue
                    text = raw.decode("utf-8", errors="replace")
                    digest = hashlib.sha256(raw).hexdigest()
                    symbols = " ".join(dict.fromkeys(SYMBOL_RE.findall(text)))[:8_000]
                    excerpt = text[:24_000]
                    conn.execute(
                        """
                        INSERT INTO project_documents(
                            root, path, language, content_hash, symbols, excerpt,
                            modified_at, indexed_at
                        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        ON CONFLICT(path) DO UPDATE SET
                            root=excluded.root,
                            language=excluded.language,
                            content_hash=excluded.content_hash,
                            symbols=excluded.symbols,
                            excerpt=excluded.excerpt,
                            modified_at=excluded.modified_at,
                            indexed_at=excluded.indexed_at
                        """,
                        (
                            str(root),
                            resolved,
                            path.suffix.casefold().lstrip("."),
                            digest,
                            symbols,
                            excerpt,
                            stat.st_mtime,
                            now,
                        ),
                    )
                    indexed += 1
                except (OSError, UnicodeError):
                    continue
        existing_paths = [
            str(row["path"])
            for row in conn.execute("SELECT path FROM project_documents").fetchall()
        ]
        removed = 0
        for path in existing_paths:
            if path not in seen and any(
                path == str(root) or path.startswith(str(root) + os.sep)
                for root in roots
            ):
                conn.execute("DELETE FROM project_documents WHERE path = ?", (path,))
                removed += 1
        conn.commit()
    result = {"indexed": indexed, "unchanged": unchanged, "removed": removed}
    record_timeline("project_indexed", "Updated project index", result)
    return result


def search_projects(query: str, limit: int = 20) -> list[dict[str, Any]]:
    tokens = re.findall(r"[A-Za-z0-9_./+-]+", query)
    if not tokens:
        return []
    fts = " AND ".join(f'"{token}"*' for token in tokens[:12])
    with database() as conn:
        _prepare_fts(conn)
        try:
            rows = conn.execute(
                """
                SELECT p.*, bm25(project_documents_fts, 4.0, 2.0, 1.0) AS rank
                FROM project_documents_fts
                JOIN project_documents p ON p.id = project_documents_fts.rowid
                WHERE project_documents_fts MATCH ?
                ORDER BY rank
                LIMIT ?
                """,
                (fts, max(1, min(int(limit), 100))),
            ).fetchall()
        except Exception:
            like = f"%{query}%"
            rows = conn.execute(
                "SELECT * FROM project_documents WHERE path LIKE ? OR symbols LIKE ? "
                "OR excerpt LIKE ? ORDER BY indexed_at DESC LIMIT ?",
                (like, like, like, max(1, min(int(limit), 100))),
            ).fetchall()
    return [dict(row) for row in rows]


def project_index_status() -> dict[str, Any]:
    with database() as conn:
        count = conn.execute("SELECT COUNT(*) FROM project_documents").fetchone()[0]
        last = conn.execute(
            "SELECT MAX(indexed_at) FROM project_documents"
        ).fetchone()[0]
    return {
        "enabled": load_config().project_index_enabled,
        "roots": [str(root) for root in _approved_roots()],
        "documents": int(count),
        "last_indexed_at": last,
    }
