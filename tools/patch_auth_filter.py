#!/usr/bin/env python3
"""Stop the auth plugins' log filters from hiding /login from the console.

Why this exists
---------------
The security logger in start.sh reads /login, /register and /changepassword
out of the *console log* (Paper prints "Steve issued server command: /login
hunter2" for every command a player types).  LoginSecurity 3.3.1 does not let
that line reach the console: its `LoggingFilter` is added to the log4j root
logger in `LoginSecurity.enable()` and returns DENY for every message that
looks like an auth command, so the line is dropped before Paper, the file log
and our parser ever see it.  AuthMe does the same thing through
`LogFilterHelper` (used by its ConsoleFilter and Log4JFilter).  That is why
"logins are not picked up" - no amount of pattern matching can find a line
that the logging framework never writes.

What this does
--------------
It rewrites *only the string constants* of those filter classes inside the
plugin jar, so the deny check can never match a real console line again:

    "/login"                   -> "[authlog-patched] /login"
    "issued server command: "  -> "[authlog-patched] issued server command: "

Nothing else changes: the class file keeps its bytecode, its structure and its
constant indices (only the bytes of those UTF-8 constants and their lengths are
rewritten), which `javap -c` on the original and the patched class proves line
by line.  The plugin keeps working exactly as before - it just cannot hide the
auth lines any more, which is what the server owner wants, because those lines
are the only place the passwords can be read from (private-logs/auth.log).

The password itself is still never written down for the verified client (see
the masking in start.sh), and the copies of the raw console logs that are
synced to the bucket have the passwords masked as well.

Usage
-----
    python3 tools/patch_auth_filter.py --check   <jar> [<jar> ...]
    python3 tools/patch_auth_filter.py --apply   <jar> [<jar> ...]
    python3 tools/patch_auth_filter.py --restore <jar> [<jar> ...]
    python3 tools/patch_auth_filter.py --selftest [--dir DIR]

    --apply keeps a copy of the untouched jar (--backup-dir, default: next to
    the jar as <jar>.authlog-orig) so --restore can put it back.
    --json prints one machine readable object per jar for start.sh.
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import struct
import sys
import zipfile
from pathlib import Path

# The marker that is put in front of every deny string.  It makes the string
# impossible to match ("issued server command: [authlog-patched] /login" never
# appears in a log) and it is what --check and the tests grep for.
PATCH_PREFIX = "[authlog-patched] "

BACKUP_SUFFIX = ".authlog-orig"

# One entry per plugin we know.  `class` is the class inside the jar that does
# the hiding, `markers` are the exact string constants that make the filter
# match.  A jar is only touched when the class file really contains one of
# them, and every marker that is found must be patchable.
RULES = [
    {
        "plugin": "LoginSecurity",
        "class": "com/lenis0012/bukkit/loginsecurity/util/LoggingFilter.class",
        "markers": [
            "/login",
            "/register",
            "/changepassword",
            "/changepass",
            "issued server command: ",
        ],
        "why": (
            "LoginSecurity 3.3.x adds this filter to the log4j root logger and "
            "denies every console line that contains 'issued server command: ' "
            "followed by one of the auth commands"
        ),
    },
    {
        "plugin": "AuthMe",
        "class": "fr/xephi/authme/output/LogFilterHelper.class",
        "markers": ["issued server command:"],
        "why": (
            "AuthMe 5.x uses this helper from ConsoleFilter and Log4JFilter to "
            "hide every auth command from the console"
        ),
    },
]

# Used by --selftest: a tiny, valid class file that prints the given strings.
# It exists so the patch can be proven on a class the JVM really loads and runs
# (tests/test_verified_client.sh does exactly that), also on machines that have
# no auth plugin jar at hand.
FIXTURE_CLASS = "com/lenis0012/bukkit/loginsecurity/util/LoggingFilter"


# --------------------------------------------------------------------------- #
# class file handling
# --------------------------------------------------------------------------- #
class ClassFile:
    """Just enough of the class file format to rewrite UTF-8 constants."""

    MAGIC = 0xCAFEBABE

    def __init__(self, data: bytes):
        self.data = data
        if len(data) < 10 or struct.unpack_from(">I", data, 0)[0] != self.MAGIC:
            raise ValueError("not a class file")
        self.major, self.minor = struct.unpack_from(">HH", data, 6)
        self.count = struct.unpack_from(">H", data, 8)[0]
        self.utf8 = []  # (index, value, length_offset, bytes_offset)
        self._walk()

    def _walk(self) -> None:
        pos = 10
        i = 1
        while i < self.count:
            tag = self.data[pos]
            pos += 1
            if tag == 1:  # CONSTANT_Utf8
                (length,) = struct.unpack_from(">H", self.data, pos)
                start = pos + 2
                value = self.data[start:start + length]
                self.utf8.append((i, value, pos, start))
                pos = start + length
            elif tag in (7, 8, 16, 19, 20):  # Class, String, MethodType, Module, Package
                pos += 2
            elif tag in (15,):  # MethodHandle
                pos += 3
            elif tag in (3, 4, 9, 10, 11, 12, 17, 18):  # int, float, refs, NameAndType, dynamic
                pos += 4
            elif tag in (5, 6):  # long, double take two slots
                pos += 8
                i += 1
            else:
                raise ValueError(f"unknown constant pool tag {tag} at {pos - 1}")
            i += 1
        if pos > len(self.data):
            raise ValueError("class file constant pool runs past the end of the file")

    def strings(self) -> list[str]:
        return [value.decode("utf-8", "replace") for _, value, _, _ in self.utf8]

    @staticmethod
    def dangerous(strings: list[str]) -> list[str]:
        """Strings that could still make a password-hiding filter deny a line.

        A class *name* may contain "/login" by accident, so only exact matches
        of an auth command and strings containing the console prefix count.
        """
        words = {
            "/login", "/l", "/log", "/register", "/reg", "/unregister", "/unreg",
            "/changepassword", "/changepass", "/cp", "/authme",
        }
        return [s for s in strings
                if not s.startswith(PATCH_PREFIX)
                and ("issued server command" in s or s in words)]

    def patch(self, markers: list[str]) -> tuple[bytes, list[str], list[str]]:
        """Prefix every marker constant, keep everything else byte identical."""
        want = {m.encode(): PATCH_PREFIX.encode() + m.encode() for m in markers}
        done: list[str] = []
        out = bytearray()
        cursor = 0
        for _, value, length_offset, bytes_offset in self.utf8:
            new = want.get(value)
            if new is None or value.startswith(PATCH_PREFIX.encode()):
                continue
            # keep the bytes before this constant, then write the longer one
            out += self.data[cursor:length_offset]
            out += struct.pack(">H", len(new))
            out += new
            cursor = bytes_offset + len(value)
            done.append(value.decode("utf-8", "replace"))
        if not done:
            return self.data, [], []
        out += self.data[cursor:]
        patched = ClassFile(bytes(out))  # re-parse, so a broken rewrite fails here
        return bytes(out), done, self.dangerous(patched.strings())


# --------------------------------------------------------------------------- #
# jar handling
# --------------------------------------------------------------------------- #
def read_text_file(path: Path) -> dict:
    """Read a whole jar into memory (plugin jars are a few MB)."""
    with zipfile.ZipFile(path) as zf:
        return {
            "comment": zf.comment,
            "entries": [(info, zf.read(info.filename)) for info in zf.infolist()],
        }


def write_jar(path: Path, entries: list, comment: bytes) -> None:
    tmp = path.with_name(path.name + ".tmp")
    with zipfile.ZipFile(tmp, "w", zipfile.ZIP_DEFLATED) as zf:
        if comment:
            zf.comment = comment
        for info, data in entries:
            zf.writestr(info, data)
    os.replace(tmp, path)


def patch_jar(path: Path, apply: bool, backup_dir: Path | None) -> dict:
    report = {
        "jar": str(path),
        "exists": path.is_file(),
        "plugin": None,
        "class": None,
        "status": "no-rule-class",
        "markers_found": [],
        "markers_patched": [],
        "residual": [],
        "backup": None,
        "error": None,
    }
    if not path.is_file():
        report["status"] = "missing"
        return report

    try:
        content = read_text_file(path)
        by_name = {info.filename: (info, data) for info, data in content["entries"]}

        changed_any = False
        errors = []
        for rule in RULES:
            entry = by_name.get(rule["class"])
            if entry is None:
                continue
            info, data = entry
            report["plugin"] = rule["plugin"]
            report["class"] = rule["class"]
            try:
                patched_bytes, done, residual = ClassFile(data).patch(rule["markers"])
            except ValueError as exc:
                report["status"] = "error"
                report["error"] = str(exc)
                return report

            strings = ClassFile(data).strings()
            found = done or [m for m in rule["markers"] if m in strings]
            report["markers_found"] = found
            if residual:
                # a deny string we cannot neutralise: refuse to touch the jar
                report["status"] = "unpatchable"
                report["residual"] = residual
                return report
            if not done:
                # nothing left to patch: either already patched or the strings
                # are not constants in this build of the plugin
                already = [s for s in strings
                           if s.startswith(PATCH_PREFIX)
                           and s[len(PATCH_PREFIX):] in rule["markers"]]
                report["status"] = "already-patched" if already else "markers-missing"
                report["markers_patched"] = already and rule["markers"] or []
                return report

            report["markers_patched"] = done
            if not apply:
                report["status"] = "would-patch"
                return report

            # write it back, keeping a copy of the original first
            backup = None
            if backup_dir is not None:
                backup_dir.mkdir(parents=True, exist_ok=True)
                backup = backup_dir / (path.name + BACKUP_SUFFIX)
                if not backup.is_file():
                    shutil.copy2(path, backup)
            elif not (path.with_name(path.name + BACKUP_SUFFIX)).is_file():
                backup = path.with_name(path.name + BACKUP_SUFFIX)
                shutil.copy2(path, backup)
            if backup is not None:
                report["backup"] = str(backup)

            entries = [(i, patched_bytes if i.filename == rule["class"] else d)
                       for i, d in content["entries"]]
            write_jar(path, entries, content["comment"])
            # read it back and prove the whole jar is intact and patched
            check = read_text_file(path)
            check_by_name = {info.filename: data for info, data in check["entries"]}
            if check_by_name.get(rule["class"]) != patched_bytes:
                errors.append(f"{rule['class']} did not survive the rewrite")
            for i, d in content["entries"]:
                if i.filename != rule["class"] and check_by_name.get(i.filename) != d:
                    errors.append(f"unrelated entry {i.filename} changed")
            report["status"] = "patched" if not errors else "error"
            report["error"] = "; ".join(errors) or None
            changed_any = True
            return report

        if report["status"] == "no-rule-class":
            report["status"] = "not-applicable"
        return report
    except (zipfile.BadZipFile, OSError) as exc:
        report["status"] = "error"
        report["error"] = f"{type(exc).__name__}: {exc}"
        return report


def restore_jar(path: Path, backup_dir: Path | None) -> dict:
    candidates = []
    if backup_dir is not None:
        candidates.append(backup_dir / (path.name + BACKUP_SUFFIX))
    candidates.append(path.with_name(path.name + BACKUP_SUFFIX))
    for backup in candidates:
        if backup.is_file():
            shutil.copy2(backup, path)
            return {"jar": str(path), "status": "restored", "backup": str(backup)}
    return {"jar": str(path), "status": "no-backup", "backup": None}


# --------------------------------------------------------------------------- #
# self test: build a class the JVM can load and run, then patch it
# --------------------------------------------------------------------------- #
class _Pool:
    """A tiny constant pool builder (dedupes entries by their key)."""

    def __init__(self):
        self.entries: list[tuple] = []
        self.index: dict = {}

    def _add(self, key, payload, slots=1):
        if key in self.index:
            return self.index[key]
        idx = len(self.entries) + 1
        self.entries.append((key, payload, slots))
        self.index[key] = idx
        if slots == 2:
            self.entries.append((None, b"", 0))
        return idx

    def utf8(self, s: str) -> int:
        b = s.encode("utf-8")
        return self._add(("utf8", s), struct.pack(">BH", 1, len(b)) + b)

    def string(self, s: str) -> int:
        # ldc needs a CONSTANT_String entry; pointing it at the Utf8 would be
        # "Illegal type at constant pool entry"
        return self._add(("string", s), struct.pack(">BH", 8, self.utf8(s)))

    def cls(self, name: str) -> int:
        return self._add(("class", name), struct.pack(">BH", 7, self.utf8(name)))

    def nat(self, name: str, desc: str) -> int:
        return self._add(("nat", name, desc),
                         struct.pack(">BHH", 12, self.utf8(name), self.utf8(desc)))

    def fieldref(self, cls: str, name: str, desc: str) -> int:
        return self._add(("field", cls, name, desc),
                         struct.pack(">BHH", 9, self.cls(cls), self.nat(name, desc)))

    def methodref(self, cls: str, name: str, desc: str) -> int:
        return self._add(("method", cls, name, desc),
                         struct.pack(">BHH", 10, self.cls(cls), self.nat(name, desc)))

    def dump(self) -> bytes:
        out = struct.pack(">H", len(self.entries) + 1)
        for _, payload, _slots in self.entries:
            out += payload
        return out


def build_fixture_class(name: str, strings: list[str]) -> bytes:
    """A valid Java 8 class whose main() prints `strings`, one per line.

    Straight line code only, so an empty StackMapTable is enough - the same
    shape javac emits for a method without branches.
    """
    pool = _Pool()
    # constant pool class entries use the internal form, "com/foo/Bar"
    this_cls = pool.cls(name.replace(".", "/"))
    super_cls = pool.cls("java/lang/Object")
    ptr = "Ljava/io/PrintStream;"
    sb = "java/lang/StringBuilder"
    main = pool.utf8("main")
    main_desc = pool.utf8("([Ljava/lang/String;)V")
    code_name = pool.utf8("Code")
    smt_name = pool.utf8("StackMapTable")
    sb_cls = pool.cls(sb)
    sb_init = pool.methodref(sb, "<init>", "()V")
    sb_append = pool.methodref(sb, "append", "(Ljava/lang/String;)Ljava/lang/StringBuilder;")
    sb_to_string = pool.methodref(sb, "toString", "()Ljava/lang/String;")
    sys_out = pool.fieldref("java/lang/System", "out", ptr)
    println = pool.methodref("java/io/PrintStream", "println", "(Ljava/lang/String;)V")

    code = bytearray()
    code += b"\xbb" + struct.pack(">H", sb_cls)      # new StringBuilder
    code += b"\x59"                                   # dup
    code += b"\xb7" + struct.pack(">H", sb_init)      # invokespecial <init>
    code += b"\x4c"                                   # astore_1
    for s in strings:
        code += b"\x2b"                               # aload_1
        idx = pool.string(s)
        if idx > 255:
            raise ValueError("fixture has too many strings for a 1 byte ldc index")
        code += b"\x12" + bytes([idx])                # ldc <string>
        code += b"\xb6" + struct.pack(">H", sb_append)
        code += b"\x57"                               # pop
    code += b"\xb2" + struct.pack(">H", sys_out)      # getstatic System.out
    code += b"\x2b"                                   # aload_1
    code += b"\xb6" + struct.pack(">H", sb_to_string)
    code += b"\xb6" + struct.pack(">H", println)
    code += b"\xb1"                                   # return

    # StackMapTable: no entries (no branch targets in this method)
    smt = struct.pack(">HI", smt_name, 2) + struct.pack(">H", 0)
    code_attr = (struct.pack(">HI", code_name, 12 + len(code) + len(smt))
                 + struct.pack(">HH", 2, 2) + struct.pack(">I", len(code))  # max_stack, max_locals
                 + bytes(code) + struct.pack(">H", 0)  # exception table
                 + struct.pack(">H", 1) + smt)         # attributes: StackMapTable
    method = (struct.pack(">HHH", 0x0009, main, main_desc)  # public static
              + struct.pack(">H", 1) + code_attr)

    out = bytearray()
    out += struct.pack(">IHH", 0xCAFEBABE, 0, 52)     # Java 8
    out += pool.dump()
    out += struct.pack(">HHH", 0x0021, this_cls, super_cls)   # public class, super
    out += struct.pack(">HHH", 0, 0, 1)                        # interfaces, fields, methods
    out += method
    out += struct.pack(">H", 0)                                # class attributes
    return bytes(out)


def selftest(directory: Path) -> dict:
    """Build fixture jars (one per rule), patch them and report the paths."""
    directory.mkdir(parents=True, exist_ok=True)
    result = {"dir": str(directory), "classes": [], "patch": []}
    for rule in RULES:
        name = rule["class"][:-len(".class")].replace("/", ".")
        cls = build_fixture_class(name, rule["markers"])
        rel = rule["class"][:-len(".class")]
        original = directory / f"{rule['plugin']}-original.jar"
        patched = directory / f"{rule['plugin']}-patched.jar"
        # a decoy class that uses the same words for its real job (the command
        # class of the plugin does exactly that): the patch must not touch it
        decoy_rel = "com/lenis0012/bukkit/loginsecurity/commands/CommandLogin"
        if rule["plugin"] != "LoginSecurity":
            decoy_rel = "fr/xephi/authme/commands/executors/LoginCommand"
        decoy = build_fixture_class(decoy_rel.replace("/", "."), ["/login", "/register"])
        for target in (original, patched):
            with zipfile.ZipFile(target, "w", zipfile.ZIP_DEFLATED) as zf:
                zf.writestr(rel + ".class", cls)
                zf.writestr(decoy_rel + ".class", decoy)
                zf.writestr("plugin.yml", f"name: {rule['plugin']}\nversion: 0\n")
        report = patch_jar(patched, apply=True, backup_dir=directory / "backup")
        result["classes"].append({"plugin": rule["plugin"], "class": name,
                                  "decoy": decoy_rel.replace("/", "."),
                                  "original": str(original), "patched": str(patched)})
        result["patch"].append(report)
    return result


# --------------------------------------------------------------------------- #
def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true", help="only report what would happen")
    mode.add_argument("--apply", action="store_true", help="patch the jars (keeps a backup)")
    mode.add_argument("--restore", action="store_true", help="put the original jar back")
    mode.add_argument("--selftest", action="store_true", help="build, patch and verify a fixture")
    parser.add_argument("--backup-dir", default=None, help="where the originals are kept")
    parser.add_argument("--json", action="store_true", help="one JSON object per line")
    parser.add_argument("--dir", default=None, help="--selftest work directory")
    parser.add_argument("jars", nargs="*")
    args = parser.parse_args(argv[1:])

    backup_dir = Path(args.backup_dir) if args.backup_dir else None

    if args.selftest:
        import tempfile
        directory = Path(args.dir) if args.dir else Path(tempfile.mkdtemp(prefix="authfilter-"))
        result = selftest(directory)
        if args.json:
            print(json.dumps(result))
        else:
            for report in result["patch"]:
                print(f"{report['plugin']}: {report['status']} "
                      f"({len(report['markers_patched'])} markers)")
            for item in result["classes"]:
                print(f"  original: {item['original']}")
                print(f"  patched : {item['patched']}")
                print(f"  run with: java -cp {item['patched']} {item['class']}")
        return 0

    if not args.jars:
        parser.error("at least one jar is required")

    reports = []
    for jar in args.jars:
        path = Path(jar)
        if args.apply:
            reports.append(patch_jar(path, apply=True, backup_dir=backup_dir))
        elif args.check:
            reports.append(patch_jar(path, apply=False, backup_dir=backup_dir))
        else:
            reports.append(restore_jar(path, backup_dir))

    ok = True
    for report in reports:
        if args.json:
            print(json.dumps(report))
        else:
            detail = report.get("class") or "-"
            note = f" [{report['error']}]" if report.get("error") else ""
            print(f"{report.get('plugin') or 'unknown plugin'}: {report['status']} ({detail}){note}")
            for marker in report.get("markers_patched") or report.get("markers_found") or []:
                print(f"    {marker}")
        if report["status"] in ("error", "unpatchable", "markers-missing"):
            ok = False
    return 0 if ok else 3


if __name__ == "__main__":
    sys.exit(main(sys.argv))
