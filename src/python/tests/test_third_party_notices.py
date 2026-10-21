from pathlib import Path


ROOT = Path(__file__).resolve().parents[3]


def test_notice_covers_required_code_and_downloaded_models() -> None:
    notices = (ROOT / "THIRD-PARTY-NOTICES.md").read_text()

    assert "Demucs (`demucs`)" in notices
    assert "ACE-Step 1.5 code, v0.1.6" in notices
    assert "Copyright (c) Meta Platforms, Inc. and affiliates." in notices
    assert "Copyright (c) 2026 ACEStep" in notices
    assert "## Downloaded on first use" in notices
    assert "docs/MODELS_AND_LICENSES.md" in notices


def test_release_copies_notices_before_signing() -> None:
    script = (ROOT / "build-release.sh").read_text()

    notices_copy = script.index('cp "THIRD-PARTY-NOTICES.md"')
    license_copy = script.index('cp "LICENSE"')
    signing = script.index("codesign --sign")
    assert notices_copy < signing
    assert license_copy < signing


def test_about_view_opens_bundled_notices_with_github_fallback() -> None:
    help_view = (ROOT / "src/swift/Sources/HelpView.swift").read_text()

    assert "import AppKit" in help_view
    assert (
        'Bundle.main.url(forResource: "THIRD-PARTY-NOTICES", withExtension: "md")'
        in help_view
    )
    assert (
        "https://github.com/Majiks-Studio/majiks-music-studio/blob/main/THIRD-PARTY-NOTICES.md"
        in help_view
    )
    assert "NSWorkspace.shared.open(noticesURL)" in help_view


def test_company_name_and_readme_link_are_current() -> None:
    trademark = (ROOT / "TRADEMARK.md").read_text()
    readme = (ROOT / "README.md").read_text()

    assert "Magic Unicorn Inc." not in trademark
    assert "Magic Unicorn Unconventional Technology & Stuff Inc." in trademark
    assert "[THIRD-PARTY-NOTICES.md](THIRD-PARTY-NOTICES.md)" in readme
