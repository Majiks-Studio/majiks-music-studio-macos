"""Trust store for the bundled interpreter.

Homebrew's OpenSSL is compiled with OPENSSLDIR=/opt/homebrew/etc/openssl@3.
The release build copies libssl and libcrypto into the app and rewrites their
load commands, which is what makes the bundle notarizable and runnable on a
Mac that has no Homebrew. The default CA file is not a load command. It stays
compiled into libcrypto as /opt/homebrew/etc/openssl@3/cert.pem.

That file exists on the machine that built the app. On a customer's Mac it
does not, and urllib fails with CERTIFICATE_VERIFY_FAILED / unable to get
local issuer certificate (_ssl.c:1010). The language-model download in the
setup wizard is one of those urllib calls.

The release build copies certifi's cacert.pem to
Python.framework/Versions/3.12/etc/ssl/cert.pem and sitecustomize points
SSL_CERT_FILE at it. This module is the same rule for code that builds its
own SSL context, and for a process whose sitecustomize was not the bundled one.
"""

from __future__ import annotations

import os
import shutil
import ssl
import sys
import urllib.request
from pathlib import Path
from typing import Optional


def framework_cafile(executable: Optional[str] = None) -> Path:
    """CA bundle shipped beside this interpreter.

    sys.executable is Versions/3.12/bin/python3.12. The bundle lives at
    Versions/3.12/etc/ssl/cert.pem. sitecustomize.py is at
    Versions/3.12/lib/python3.12/sitecustomize.py and reaches the same file
    with ../.. from its own directory. Those two relatives must stay in step.
    """
    exe = Path(executable or sys.executable).resolve()
    return exe.parent.parent / "etc" / "ssl" / "cert.pem"


def bundled_cafile(executable: Optional[str] = None) -> Optional[str]:
    """Return a CA bundle that exists, or None.

    An SSL_CERT_FILE that names a real file wins, so a proxy's own root still
    works. A set-but-missing SSL_CERT_FILE does not hide the bundled file:
    that missing Homebrew path is the customer failure.
    """
    env = os.environ.get("SSL_CERT_FILE")
    if env and os.path.isfile(env):
        return env

    candidate = framework_cafile(executable)
    if candidate.is_file():
        return str(candidate)

    try:
        import certifi
    except ImportError:
        return None
    path = certifi.where()
    if path and os.path.isfile(path):
        return path
    return None


def install_ca_env(executable: Optional[str] = None) -> Optional[str]:
    """Point the process at a CA bundle that is actually on disk.

    Does not override a CA file the user, or a TLS-inspecting proxy, already
    configured. Called at backend startup so every urllib.request.urlopen in
    the process uses it, not only the language-model download.
    """
    current = os.environ.get("SSL_CERT_FILE")
    if current and not os.path.isfile(current):
        os.environ.pop("SSL_CERT_FILE", None)
        current = None

    cafile = current if current else bundled_cafile(executable)
    if not cafile:
        return None

    os.environ["SSL_CERT_FILE"] = cafile
    for key in ("REQUESTS_CA_BUNDLE", "CURL_CA_BUNDLE"):
        existing = os.environ.get(key)
        if not existing or not os.path.isfile(existing):
            os.environ[key] = cafile
    return cafile


def https_context(executable: Optional[str] = None) -> ssl.SSLContext:
    cafile = bundled_cafile(executable)
    if cafile:
        return ssl.create_default_context(cafile=cafile)
    return ssl.create_default_context()


def https_urlretrieve(url: str, filename: str) -> None:
    """Stream ``url`` to ``filename`` using the bundled trust store.

    urllib.request.urlretrieve has no context argument, so it uses OpenSSL's
    compiled-in default. That default is the Homebrew cert path.
    """
    dest = Path(filename)
    dest.parent.mkdir(parents=True, exist_ok=True)
    partial = dest.with_name(dest.name + ".part")
    try:
        with urllib.request.urlopen(url, context=https_context()) as resp:
            with partial.open("wb") as out:
                shutil.copyfileobj(resp, out, length=1024 * 1024)
        os.replace(partial, dest)
    finally:
        # replace() already removed the partial on success. On failure, drop it
        # so a half-written file is not mistaken for a finished download.
        partial.unlink(missing_ok=True)
