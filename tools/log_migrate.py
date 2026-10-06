#!/usr/bin/env python3
"""Migrate the old many-file logs into the compact, date-divided log layout.

The old Docker image used UTC by default. Its timestamps are converted to the
requested display timezone; new events are timestamped by start.sh directly in
that zone. This does not rewrite or guess timestamps in the live Paper logs.
"""
from __future__ import annotations

import argparse
import os
import re
import sys
import tempfile
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from zoneinfo import ZoneInfo, ZoneInfoNotFoundError

FORMAT_MARKER = "# log-format: 2"
LEGACY_STAMP = re.compile(r"^(\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}) \| (.*)$")

VERDICT_LABELS = {
    "VERIFIED": "VERIFIED CLIENT",
    "UNVERIFIED": "OTHER EAGLERCRAFT CLIENT",
    "VANILLA": "JAVA CLIENT",
    "PENDING": "CHECK PENDING",
    "CONSOLE_DOWN": "CONSOLE DOWN",
    "UNKNOWN": "UNKNOWN CLIENT",
}


@dataclass(frozen=True)
class Record:
    epoch: float
    order: int
    message: str


def _legacy_epoch(value: str) -> float:
    """The old Debian image used UTC (its default); convert that wall time."""
    parsed = datetime.strptime(value, "%Y-%m-%d %H:%M:%S")
    return parsed.replace(tzinfo=timezone.utc).timestamp()


def _local_stamp(epoch: float, zone: ZoneInfo) -> tuple[str, str, str]:
    local = datetime.fromtimestamp(epoch, zone)
    day = local.strftime("%Y-%m-%d")
    stamp = local.strftime("%Y-%m-%d %I:%M:%S %p %Z")
    weekday = f"{local.strftime('%A, %B')} {local.day}, {local.year}"
    return day, stamp, weekday


def _read_timestamped(path: Path, zone: ZoneInfo, convert, order_start: int) -> list[Record]:
    records: list[Record] = []
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return records

    for index, line in enumerate(lines):
        match = LEGACY_STAMP.match(line)
        if not match:
            if not line.strip() or line.startswith("#") or line.startswith("==="):
                continue
            # Do not silently throw away a malformed historical row. Keep it
            # in a dated LEGACY event with an explicit unavailable timestamp.
            epoch = datetime.now(timezone.utc).timestamp()
            records.append(Record(epoch, order_start + index, f"LEGACY | timestamp unavailable | {line}"))
            continue
        epoch = _legacy_epoch(match.group(1))
        message = convert(match.group(2))
        if message:
            records.append(Record(epoch, order_start + index, message))
    return records


def _activity_records(security_dir: Path) -> list[Record]:
    records: list[Record] = []
    checks_path = security_dir / "client-checks.log"
    has_checks = checks_path.is_file() and checks_path.stat().st_size > 0

    def keep_login(payload: str) -> str:
        parts = payload.split(" | ", 1)
        kind = parts[0]
        if kind == "VERIFY":
            # The old login file and client-checks.log both stored the same
            # result. Prefer the richer check row below, exactly once.
            if has_checks:
                return ""
            legacy = parts[1] if len(parts) > 1 else "legacy verification"
            legacy = re.sub(r"(?i)(brand|uuid)=([^|]*)", r"\1=redacted", legacy)
            return "CHECK | " + legacy
        return payload

    def command(payload: str) -> str:
        return "COMMAND | " + payload

    def check(payload: str) -> str:
        parts = payload.split(" | ")
        if len(parts) < 4:
            return "CHECK | " + payload
        verdict, name, ip = parts[0], parts[1], parts[2]
        label = VERDICT_LABELS.get(verdict, "UNKNOWN CLIENT")
        details = parts[3:]
        if verdict == "VERIFIED":
            # Do not move the verified client's real address, brand or UUID
            # into the public activity log. The private address history remains
            # the owner-readable source of the actual IP.
            ip = "hidden"
            version = next((p for p in details if p.startswith("version=")), "version=redacted")
            details = ["brand=redacted", version, "uuid=redacted"]
        return "CHECK | " + " | ".join([name, ip, f"client={label}", *details])

    sources = (
        ("logins.log", keep_login),
        ("commands.log", command),
        ("client-checks.log", check),
    )
    for source_index, (filename, transform) in enumerate(sources):
        path = security_dir / filename
        records.extend(_read_timestamped(path, ZoneInfo("UTC"), transform,
                                         source_index * 1_000_000))
    records.sort(key=lambda row: (row.epoch, row.order))
    return records


def _write_dated(path: Path, records: list[Record], zone: ZoneInfo, marker_note: str) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    lines = [f"{FORMAT_MARKER}; timezone={zone.key}; 12-hour clock", marker_note]
    current_day = None
    for record in records:
        day, stamp, weekday = _local_stamp(record.epoch, zone)
        if day != current_day:
            if current_day is not None:
                lines.append("")
            lines.append(f"==================== {weekday} | {day} ====================")
            lines.append("")
            current_day = day
        lines.append(f"{stamp} | {record.message}")
    payload = "\n".join(lines) + "\n"
    mode = 0o600 if "private-logs" in path.parts else 0o644
    try:
        mode = path.stat().st_mode & 0o777
    except OSError:
        pass
    fd, temp_name = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as stream:
            stream.write(payload)
            stream.flush()
            os.fsync(stream.fileno())
        os.chmod(temp_name, mode)
        os.replace(temp_name, path)
    finally:
        try:
            os.unlink(temp_name)
        except FileNotFoundError:
            pass


def _has_marker(path: Path) -> bool:
    try:
        with path.open("r", encoding="utf-8", errors="replace") as stream:
            return FORMAT_MARKER in stream.readline()
    except OSError:
        return False


def _migrate_append_log(path: Path, zone: ZoneInfo, transform=lambda x: x) -> bool:
    if _has_marker(path):
        return False
    records = _read_timestamped(path, zone, transform, 0)
    note = f"# Previous timestamps converted from the old container's UTC clock to {zone.key}."
    _write_dated(path, records, zone, note)
    return bool(records)


def _verified_names(security_dir: Path, private_dir: Path) -> set[str]:
    """Names already identified as the owner, from durable historical evidence."""
    names: set[str] = set()

    state = private_dir / "verified-players.txt"
    if state.is_file():
        names.update(line.strip().casefold() for line in state.read_text(
            encoding="utf-8", errors="replace").splitlines() if line.strip())

    for filename in ("client-checks.log", "logins.log"):
        path = security_dir / filename
        if not path.is_file():
            continue
        for line in path.read_text(encoding="utf-8", errors="replace").splitlines():
            match = LEGACY_STAMP.match(line)
            if not match:
                continue
            parts = match.group(2).split(" | ")
            if not parts:
                continue
            if filename == "client-checks.log" and parts[0].upper() == "VERIFIED" and len(parts) > 1:
                names.add(parts[1].casefold())
            elif filename == "client-checks.log" and parts[0].upper() == "CHECK" and len(parts) > 1:
                if any("VERIFIED CLIENT" in part.upper() for part in parts[2:]):
                    names.add(parts[1].casefold())
            elif filename == "logins.log" and parts[0].upper() in {"VERIFY", "CHECK"} and len(parts) > 1:
                if any("VERIFIED" in part.upper() for part in parts[2:]):
                    names.add(parts[1].casefold())
    return names


def _mask_verified_auth(names: set[str]):
    """Never migrate a verified owner's historical auth password in clear."""
    auth_command = re.compile(
        r"^([^|]+) \| ([^|]+) \| (/(?:login|l|log|register|reg|unregister|unreg|"
        r"changepassword|changepass|cp|authme))\b.*$", re.IGNORECASE)

    def transform(payload: str) -> str:
        match = auth_command.match(payload)
        if not match or match.group(1).strip().casefold() not in names:
            return payload
        name = match.group(1).strip()
        command = match.group(3)
        return f"{name} | hidden | {command} ******** | client=VERIFIED CLIENT (password not recorded)"

    return transform


def _migrate_activity(security_dir: Path, zone: ZoneInfo) -> int:
    target = security_dir / "activity.log"
    if _has_marker(target):
        return 0
    records = _activity_records(security_dir)
    note = (f"# Previous timestamps converted from UTC to {zone.key}; "
            "VERIFIED brand and UUID values are redacted.")
    _write_dated(target, records, zone, note)
    return len(records)


def _migrate_addresses(private_dir: Path, zone: ZoneInfo) -> int:
    target = private_dir / "addresses.log"
    if _has_marker(target):
        return 0

    records: list[Record] = []
    candidates = [private_dir / "player-ips.log"]
    # The old real-IP login file is another copy of information in the IP map.
    # Only use it to fill a missing account/address pair; keep all sightings
    # from player-ips.log as the canonical private history.
    seen: set[tuple[str, str]] = set()

    for line_index, line in enumerate(candidates[0].read_text(encoding="utf-8", errors="replace").splitlines()
                                        if candidates[0].exists() else []):
        match = LEGACY_STAMP.match(line)
        if not match:
            continue
        rest = match.group(2).split(" | ")
        if len(rest) < 3:
            continue
        name, ip, source = rest[0], rest[1], rest[2]
        source = source.removeprefix("source=")
        seen.add((name, ip))
        records.append(Record(_legacy_epoch(match.group(1)), line_index,
                              f"IP | {name} | {ip} | source={source}"))

    private_logins = private_dir / "logins-real-ips.log"
    if private_logins.exists():
        for line_index, line in enumerate(private_logins.read_text(encoding="utf-8", errors="replace").splitlines(),
                                           start=len(records)):
            match = LEGACY_STAMP.match(line)
            if not match:
                continue
            rest = match.group(2).split(" | ")
            if len(rest) < 4 or rest[0] != "LOGIN":
                continue
            name, ip = rest[1], rest[2]
            if ip in {"", "unknown", "hidden"} or (name, ip) in seen:
                continue
            seen.add((name, ip))
            records.append(Record(_legacy_epoch(match.group(1)), line_index,
                                  f"IP | {name} | {ip} | source=legacy-login"))

    records.sort(key=lambda row: (row.epoch, row.order))
    note = f"# Private address history; previous timestamps converted from UTC to {zone.key}."
    _write_dated(target, records, zone, note)
    return len(records)


def migrate(security_dir: Path, private_dir: Path, zone_name: str) -> tuple[int, int, list[Path]]:
    try:
        zone = ZoneInfo(zone_name)
    except ZoneInfoNotFoundError as exc:
        raise SystemExit(f"unknown timezone {zone_name!r}; install tzdata") from exc
    security_dir.mkdir(parents=True, exist_ok=True)
    private_dir.mkdir(parents=True, exist_ok=True)

    # Read ownership evidence before any legacy inputs are removed. The old
    # private auth log remains available for other players, but a verified
    # owner's legacy credentials are never copied into the new bucket log.
    verified_names = _verified_names(security_dir, private_dir)
    activity_count = _migrate_activity(security_dir, zone)
    _migrate_append_log(private_dir / "auth.log", zone, _mask_verified_auth(verified_names))
    address_count = _migrate_addresses(private_dir, zone)

    # These were duplicate views of the same login/check/IP data. The new
    # per-directory sync uses --delete so these also disappear from the bucket.
    legacy_paths = [
        security_dir / name for name in (
            "logins.log", "commands.log", "client-checks.log", "shared-ips.txt",
            "ip-report.log", "logger-status.log", "proxy-peers.txt",
        )
    ] + [
        private_dir / name for name in (
            "player-ips.log", "ip-report-private.log", "logins-real-ips.log",
            "shared-ips-private.txt",
        )
    ]
    removed = []
    for path in legacy_paths:
        try:
            path.unlink()
            removed.append(path)
        except FileNotFoundError:
            pass
    return activity_count, address_count, removed


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("security_dir", type=Path)
    parser.add_argument("private_dir", type=Path)
    parser.add_argument("--timezone", default="America/New_York")
    args = parser.parse_args(argv)
    activity_count, address_count, removed = migrate(args.security_dir, args.private_dir, args.timezone)
    print(f"log-migrate: activity_rows={activity_count} address_rows={address_count} "
          f"legacy_files_removed={len(removed)} timezone={args.timezone}", flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
