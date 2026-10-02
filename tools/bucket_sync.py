#!/usr/bin/env python3
"""
bucket_sync.py - copy a local directory into a Hugging Face *bucket*.

Why this exists: everything the server logs is meant to be readable from the
bucket, but the upload happens from inside the Space and the `hf` CLI there can
fail for reasons the Space itself can only report (missing CLI, read-only
token, an older CLI without `hf buckets`, ...).  This script is the fallback:
it needs nothing but `huggingface_hub`, which the Space image already installs.

usage:
    bucket_sync.py <local_dir> <bucket_id> <prefix> [--delete] [--token TOKEN]
    bucket_sync.py --probe <bucket_id> [--prefix P] [--token TOKEN]
    bucket_sync.py --whoami  [--token TOKEN]

`bucket_id` is `namespace/name` (the part after `hf://buckets/`), `prefix` is
the folder inside the bucket (may be empty).

It prints exactly one summary line that start.sh logs:

    bucket-sync: uploaded=3 skipped=2 deleted=1 bytes=4096 prefix=game-data method=batch

Exit code 0 = the bucket is up to date, 1 = something failed (the reason is
printed to stderr as well, so it shows up in the Space logs).
"""

import argparse
import os
import sys
from pathlib import Path

SUMMARY_PREFIX = "bucket-sync:"


def log(msg):
    print(msg, flush=True)


def fail(msg, code=1):
    print(f"bucket-sync: ERROR {msg}", file=sys.stderr, flush=True)
    raise SystemExit(code)


def load_api(token=None):
    try:
        from huggingface_hub import HfApi
    except Exception as exc:  # pragma: no cover - only when the image is broken
        fail(f"huggingface_hub is not installed ({exc}). "
             f"pip install 'huggingface_hub[cli]' in the image")
    try:
        return HfApi(token=token)
    except Exception as exc:
        fail(f"could not create the Hub client ({exc})")


def whoami(api):
    try:
        info = api.whoami()
    except Exception as exc:
        fail(f"the token is not usable ({exc.__class__.__name__}: {exc})")
    name = info.get("name") or info.get("user") or "?"
    role = "?"
    auth = info.get("auth") or {}
    access = (auth.get("accessToken") or {}) if isinstance(auth, dict) else {}
    if isinstance(access, dict):
        role = access.get("role") or role
    log(f"{SUMMARY_PREFIX} user={name} token_role={role}")
    return name, role


def iter_local(root):
    for dirpath, _dirnames, filenames in os.walk(root):
        for name in sorted(filenames):
            path = Path(dirpath) / name
            try:
                size = path.stat().st_size
            except OSError:
                continue
            yield path.relative_to(root).as_posix(), path, size


def join(prefix, rel):
    return f"{prefix}/{rel}" if prefix else rel


def strip_prefix(path, prefix):
    if prefix and path.startswith(prefix + "/"):
        return path[len(prefix) + 1:]
    return path


def list_remote(api, bucket_id, prefix):
    """{relative path: size} of what is already in the bucket under prefix."""
    try:
        tree = api.list_bucket_tree(bucket_id, prefix=prefix or None, recursive=True)
    except TypeError:                      # older signature
        tree = api.list_bucket_tree(bucket_id, recursive=True)
    except Exception as exc:
        fail(f"could not list the bucket ({exc.__class__.__name__}: {exc}). "
             f"Does the token have write access to {bucket_id}?")
    out = {}
    for item in tree:
        path = getattr(item, "path", None) or getattr(item, "file_path", None)
        size = getattr(item, "size", None)
        if path is None or size is None:   # folders have no size
            continue
        out[strip_prefix(path, prefix)] = size
    return out


def batch(api, bucket_id, add, delete):
    if api is not None and hasattr(api, "batch_bucket_files"):
        api.batch_bucket_files(bucket_id, add=add or None, delete=delete or None)
        return "batch"
    try:
        from huggingface_hub import batch_bucket_files as fn
    except Exception:
        fn = None
    if fn is not None:
        fn(bucket_id, add=add or None, delete=delete or None)
        return "batch"
    # last resort: the directory sync of huggingface_hub >= 1.5
    if hasattr(api, "sync_bucket"):
        return "sync"
    fail("this huggingface_hub has no bucket upload API - "
         "upgrade it (`pip install -U 'huggingface_hub[cli]'`)")


def cmd_sync(args):
    api = load_api(args.token)
    root = Path(args.local_dir)
    if not root.is_dir():
        fail(f"{root} is not a directory")

    local = {rel: size for rel, _path, size in iter_local(root)}
    remote = list_remote(api, args.bucket_id, args.prefix)

    add = [(str(path), join(args.prefix, rel), size)
           for rel, path, size in iter_local(root)
           if remote.get(rel) != size]
    delete = [join(args.prefix, rel) for rel in remote
              if args.delete and rel not in local]

    method = "batch"
    if add or delete:
        method = batch(api, args.bucket_id, [(src, dst) for src, dst, _size in add], delete)
        if method == "sync":               # fallback for other library versions
            api.sync_bucket(str(root), f"hf://buckets/{args.bucket_id}"
                            + (f"/{args.prefix}" if args.prefix else ""),
                            delete=args.delete)
    log(f"{SUMMARY_PREFIX} uploaded={len(add)} skipped={len(local) - len(add)} "
        f"deleted={len(delete)} bytes={sum(size for _s, _d, size in add)} "
        f"prefix={args.prefix or '.'} method={method}")
    return 0


def cmd_probe(args):
    api = load_api(args.token)
    whoami(api)
    marker = join(args.prefix, ".write-probe")
    try:
        api.batch_bucket_files(args.bucket_id, add=[(b"probe", marker)])
        api.batch_bucket_files(args.bucket_id, delete=[marker])
    except Exception as exc:
        fail(f"no write access to {args.bucket_id} ({exc.__class__.__name__}: {exc})")
    log(f"{SUMMARY_PREFIX} probe ok - {args.bucket_id} is writable")
    return 0


def cmd_create(args):
    api = load_api(args.token)
    try:
        api.create_bucket(args.bucket_id, private=True, exist_ok=True)
    except Exception as exc:
        log(f"{SUMMARY_PREFIX} could not create {args.bucket_id} "
            f"({exc.__class__.__name__}: {exc}) - assuming it exists")
        return 0
    log(f"{SUMMARY_PREFIX} bucket {args.bucket_id} ready")
    return 0


def cmd_whoami(args):
    whoami(load_api(args.token))
    return 0


def main(argv=None):
    ap = argparse.ArgumentParser(add_help=True)
    ap.add_argument("local_dir", nargs="?")
    ap.add_argument("bucket_id", nargs="?")
    ap.add_argument("prefix", nargs="?", default="")
    ap.add_argument("--delete", action="store_true",
                    help="also remove bucket files that are not local anymore")
    ap.add_argument("--probe", action="store_true",
                    help="only test that the token can write to the bucket")
    ap.add_argument("--create", action="store_true",
                    help="only make sure the bucket exists")
    ap.add_argument("--whoami", action="store_true",
                    help="print the token's user and role, then exit")
    ap.add_argument("--token", default=os.environ.get("HF_TOKEN") or None)
    args = ap.parse_args(argv)

    # --probe/--create take the bucket id as their only argument, so it can
    # land in either position
    if args.whoami:
        return cmd_whoami(args)
    if args.probe or args.create:
        args.bucket_id = args.bucket_id or args.local_dir
        if not args.bucket_id:
            ap.error("--probe/--create need a bucket id (namespace/name)")
        return cmd_probe(args) if args.probe else cmd_create(args)
    if not args.local_dir or not args.bucket_id:
        ap.error("local_dir and bucket_id are required (or use --probe/--whoami)")
    return cmd_sync(args)


if __name__ == "__main__":
    sys.exit(main())
