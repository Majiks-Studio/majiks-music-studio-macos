"""Manage ACE-Step gate keys. The gate re-reads the key file on every request; no restart needed.

  python gate_keys.py add NAME [--days 365]   print a new key ONCE on stdout and store only its hash
  python gate_keys.py revoke NAME             refuse that key from now on
  python gate_keys.py list                    names, expiry, status (never key values)

The key goes to stdout alone so it can be piped straight into a password manager, e.g.
  python gate_keys.py add alice | your-vault-cli store "acestep-gate: alice"
Everything else goes to stderr.
"""

import argparse
import datetime as dt
import hashlib
import json
import os
import secrets
import sys
from pathlib import Path

KEYS_FILE = Path(os.getenv("GATE_KEYS_FILE", Path(__file__).resolve().parent / "keys.json"))


def load() -> list:
    try:
        return json.loads(KEYS_FILE.read_text())
    except FileNotFoundError:
        return []


def save(keys: list) -> None:
    tmp = KEYS_FILE.with_suffix(".tmp")
    tmp.write_text(json.dumps(keys, indent=1))
    os.chmod(tmp, 0o600)
    tmp.replace(KEYS_FILE)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = ap.add_subparsers(dest="cmd", required=True)
    a = sub.add_parser("add")
    a.add_argument("name")
    a.add_argument("--days", type=int, default=365)
    r = sub.add_parser("revoke")
    r.add_argument("name")
    sub.add_parser("list")
    args = ap.parse_args()

    keys = load()
    today = dt.date.today()
    if args.cmd == "add":
        if any(k["name"] == args.name and not k.get("revoked") for k in keys):
            print(f"An active key named {args.name!r} exists; revoke it first.", file=sys.stderr)
            return 1
        token = "mms_" + secrets.token_urlsafe(32)
        digest = hashlib.sha256(token.encode()).hexdigest()
        expires = (today + dt.timedelta(days=args.days)).isoformat()
        keys.append({"name": args.name, "sha256": digest, "expires": expires, "created": today.isoformat()})
        save(keys)
        print(f"added {args.name} (sha8 {digest[:8]}), expires {expires}", file=sys.stderr)
        sys.stdout.write(token)
        return 0
    if args.cmd == "revoke":
        hits = [k for k in keys if k["name"] == args.name and not k.get("revoked")]
        if not hits:
            print(f"No active key named {args.name!r}.", file=sys.stderr)
            return 1
        for k in hits:
            k["revoked"] = True
            k["revoked_at"] = today.isoformat()
        save(keys)
        print(f"revoked {args.name}", file=sys.stderr)
        return 0
    for k in keys:
        state = "revoked" if k.get("revoked") else ("expired" if k.get("expires", "9999") < today.isoformat() else "active")
        print(f"{k['name']:<24} {k['sha256'][:8]}  expires {k.get('expires', '-')}  {state}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
