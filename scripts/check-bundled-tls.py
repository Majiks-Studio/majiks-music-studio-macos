#!/usr/bin/env python3
"""Fail if this interpreter's HTTPS trust store is outside the app bundle.

Run it with the bundled python3.12, after signing, with SSL_CERT_FILE,
REQUESTS_CA_BUNDLE and CURL_CA_BUNDLE unset in the environment. sitecustomize
must then point the default CA file at Versions/3.12/etc/ssl/cert.pem, and a
handshake to Hugging Face must succeed without /opt/homebrew on disk.

  env -u SSL_CERT_FILE -u REQUESTS_CA_BUNDLE -u CURL_CA_BUNDLE \
      PYTHONDONTWRITEBYTECODE=1 \
      Contents/Frameworks/Python.framework/Versions/3.12/bin/python3.12 \
      -B scripts/check-bundled-tls.py
"""

from __future__ import annotations

import os
import ssl
import sys
import urllib.request


def main() -> int:
    exe = os.path.realpath(sys.executable)
    framework_version = os.path.dirname(os.path.dirname(exe))  # Versions/3.12
    ca = ssl.get_default_verify_paths().cafile or ""
    ca_real = os.path.realpath(ca) if ca else ""

    if not ca_real or not os.path.isfile(ca_real):
        print(f"FAIL: default CA file is missing: {ca!r}", file=sys.stderr)
        print("      urllib would report CERTIFICATE_VERIFY_FAILED /", file=sys.stderr)
        print("      unable to get local issuer certificate.", file=sys.stderr)
        return 1

    if not ca_real.startswith(framework_version + os.sep):
        print(f"FAIL: default CA file is not inside the bundled framework: {ca_real}", file=sys.stderr)
        print(f"      interpreter: {exe}", file=sys.stderr)
        print("      A Homebrew path here works on the build machine and fails", file=sys.stderr)
        print("      on every customer's Mac.", file=sys.stderr)
        return 1

    try:
        with urllib.request.urlopen("https://huggingface.co", timeout=30) as resp:
            status = resp.status
    except Exception as exc:  # noqa: BLE001 — the probe's whole job is to surface this
        print(f"FAIL: handshake to https://huggingface.co failed: {exc}", file=sys.stderr)
        print(f"      CA file was {ca_real}", file=sys.stderr)
        return 1

    if status != 200:
        print(f"FAIL: https://huggingface.co returned HTTP {status}", file=sys.stderr)
        return 1

    print(f"  Bundled TLS trust store: {ca_real}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
