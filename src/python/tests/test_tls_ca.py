"""The bundled interpreter must not trust a CA file that only exists on the build Mac."""

from __future__ import annotations

import os
import ssl
import urllib.request
from pathlib import Path

import pytest

from majik_backend.tls import bundled_cafile, framework_cafile, https_context, https_urlretrieve, install_ca_env


def _layout(tmp_path: Path) -> tuple[Path, Path]:
    root = tmp_path / "Versions" / "3.12"
    exe = root / "bin" / "python3.12"
    exe.parent.mkdir(parents=True)
    exe.write_text("")
    cert = root / "etc" / "ssl" / "cert.pem"
    cert.parent.mkdir(parents=True)
    cert.write_text("not a real certificate\n")
    return exe, cert


def test_framework_cafile_matches_sitecustomize_relative(tmp_path: Path) -> None:
    exe, cert = _layout(tmp_path)
    # sitecustomize.py lives at Versions/3.12/lib/python3.12/sitecustomize.py
    # and joins ../.. / etc/ssl/cert.pem. Same file as framework_cafile().
    sitecustomize = exe.parent.parent / "lib" / "python3.12" / "sitecustomize.py"
    relative = Path(os.path.normpath(os.path.join(os.path.dirname(sitecustomize), "..", "..", "etc", "ssl", "cert.pem")))
    assert framework_cafile(str(exe)) == cert.resolve()
    assert relative.resolve() == cert.resolve()


def test_missing_ssl_cert_file_does_not_hide_bundled_cert(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    exe, cert = _layout(tmp_path)
    monkeypatch.setenv("SSL_CERT_FILE", str(tmp_path / "no-such-cert.pem"))
    assert bundled_cafile(str(exe)) == str(cert.resolve())


def test_real_ssl_cert_file_wins(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    exe, _cert = _layout(tmp_path)
    custom = tmp_path / "proxy-root.pem"
    custom.write_text("proxy\n")
    monkeypatch.setenv("SSL_CERT_FILE", str(custom))
    assert bundled_cafile(str(exe)) == str(custom)


def test_install_ca_env_replaces_a_missing_pointer(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    exe, cert = _layout(tmp_path)
    missing = tmp_path / "absent" / "cert.pem"
    monkeypatch.setenv("SSL_CERT_FILE", str(missing))
    monkeypatch.delenv("REQUESTS_CA_BUNDLE", raising=False)
    monkeypatch.delenv("CURL_CA_BUNDLE", raising=False)
    found = install_ca_env(str(exe))
    assert found == str(cert.resolve())
    assert os.environ["SSL_CERT_FILE"] == str(cert.resolve())
    assert os.environ["REQUESTS_CA_BUNDLE"] == str(cert.resolve())
    assert os.environ["CURL_CA_BUNDLE"] == str(cert.resolve())


def test_install_ca_env_keeps_a_real_override(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    exe, _cert = _layout(tmp_path)
    custom = tmp_path / "proxy-root.pem"
    custom.write_text("proxy\n")
    monkeypatch.setenv("SSL_CERT_FILE", str(custom))
    monkeypatch.setenv("REQUESTS_CA_BUNDLE", str(custom))
    assert install_ca_env(str(exe)) == str(custom)
    assert os.environ["SSL_CERT_FILE"] == str(custom)


def test_https_context_loads_when_a_real_bundle_exists() -> None:
    ca = bundled_cafile()
    if not ca:
        pytest.skip("this interpreter has no CA bundle")
    ctx = https_context()
    assert ctx.verify_mode == ssl.CERT_REQUIRED
    assert ctx.check_hostname is True


def test_https_urlretrieve_passes_a_context(tmp_path: Path, monkeypatch: pytest.MonkeyPatch) -> None:
    captured: dict = {}

    class Resp:
        def __init__(self) -> None:
            self._chunks = [b"hello", b""]

        def read(self, _n: int = -1) -> bytes:
            return self._chunks.pop(0)

        def __enter__(self) -> "Resp":
            return self

        def __exit__(self, *_args: object) -> bool:
            return False

    def fake_urlopen(url, timeout=None, context=None):  # noqa: ANN001
        captured["url"] = url
        captured["context"] = context
        return Resp()

    monkeypatch.setattr(urllib.request, "urlopen", fake_urlopen)
    dest = tmp_path / "model" / "config.json"
    https_urlretrieve("https://huggingface.co/example/resolve/main/config.json", str(dest))
    assert dest.read_bytes() == b"hello"
    assert captured["context"] is not None
    assert not dest.with_name("config.json.part").exists()
