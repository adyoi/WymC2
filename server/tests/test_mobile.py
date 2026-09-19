"""Server tests for the mobile agent (Android APK / iOS IPA) feature.

Covers the pure-Python icon generator, deterministic artifact naming, name
sanitization, and the "unavailable toolchain" failure path that every build
must hit gracefully on a host without Android/iOS SDKs.
"""
import re
import shutil
import sys
import time
from struct import unpack

import pytest

import icons
import main

KNOWN_KINDS = ("pdf", "docx", "xlsx", "pptx", "zip", "rar", "none")


@pytest.fixture
def no_mobile_toolchain(monkeypatch):
    """Simulate a host without Android/iOS SDKs or the ios-builder CLI,
    regardless of the runner."""
    real_which = shutil.which

    def fake_which(name, *args, **kwargs):
        if name in ("gradle", "gradle.bat", "xcrun", "xcrun.bat",
                    "builder", "builder.exe", "builder.bat"):
            return None
        return real_which(name, *args, **kwargs)

    monkeypatch.setattr(shutil, "which", fake_which)


def _png_wh(data: bytes) -> tuple[int, int]:
    assert data[:8] == b"\x89PNG\r\n\x1a\n", "not a PNG signature"
    return unpack(">II", data[16:24])


# ---------------------------------------------------------------------------
# Icon generator
# ---------------------------------------------------------------------------

def test_icon_png_signature_and_dims():
    png = icons.render_file_icon("pdf", 192)
    w, h = _png_wh(png)
    assert (w, h) == (192, 192)
    assert icons.render_file_icon("none", 48).startswith(b"\x89PNG\r\n\x1a\n")


def test_icon_is_deterministic_and_distinct():
    assert icons.render_file_icon("pdf", 192) == icons.render_file_icon("pdf", 192)
    blobs = {k: icons.render_file_icon(k, 96) for k in KNOWN_KINDS}
    assert len(set(blobs.values())) == len(KNOWN_KINDS)
    assert blobs["none"] != blobs["pdf"] != blobs["zip"]


def test_icon_unknown_kind_falls_back_to_none():
    assert icons.render_file_icon("bogus", 64) == icons.render_file_icon("none", 64)
    assert icons.render_file_icon("", 64) == icons.render_file_icon("none", 64)


def test_android_mipmap_set():
    sizes = {px for px, _ in icons.android_mipmaps("pdf").values()}
    assert sizes == {48, 72, 96, 144, 192}
    for dpi, (px, png) in icons.android_mipmaps("xlsx").items():
        assert _png_wh(png) == (px, px)
        assert dpi in ("mdpi", "hdpi", "xhdpi", "xxhdpi", "xxxhdpi")


def test_ios_appicon_set_includes_1024_marketing_icon():
    iconset = icons.ios_appicons("rar")
    assert "AppIcon-1024.png" in iconset
    assert _png_wh(iconset["AppIcon-1024.png"][1]) == (1024, 1024)
    assert "AppIcon-60@3x.png" in iconset
    assert _png_wh(iconset["AppIcon-60@3x.png"][1]) == (180, 180)


# ---------------------------------------------------------------------------
# Naming + sanitization
# ---------------------------------------------------------------------------

def test_mobile_artifact_names():
    assert main._artifact_name("android", "android", ".apk") == "wym_android.apk"
    assert main._artifact_name("ios", "ios", ".ipa") == "wym_ios.ipa"
    assert main._artifact_name("go", "win_x64", ".exe") == "wym_go_win_x64.exe"


def test_mobile_name_sanitization():
    assert main._sanitize_mobile_name('  Reports v2  ') == "Reports v2"
    assert main._sanitize_mobile_name("../../etc/passwd") == "etcpasswd"
    assert main._sanitize_mobile_name("a" * 500) == "a" * 48
    assert main._sanitize_mobile_name("") == "WymC2"
    assert main._sanitize_mobile_name("เปิด เซสชัน") in ("WymC2",)


def test_mobile_hash_includes_variant():
    base = main._source_hash("android", "pdf|Notes|http://h:1|t|10")
    assert main._source_hash("android", "pdf|Notes|http://h:1|t|10") == base
    assert main._source_hash("android", "zip|Notes|http://h:1|t|10") != base
    assert main._source_hash("android", "pdf|Notes|http://h:1|t|10") != main._source_hash("ios", "pdf|Notes|http://h:1|t|10")


# ---------------------------------------------------------------------------
# Build failure path (no toolchain on the test host)
# ---------------------------------------------------------------------------

@pytest.mark.parametrize("language,target,msg", [
    ("android", "android", "gradle not found"),
    ("ios", "ios", "ios-builder"),
])
def test_mobile_build_graceful_error_without_toolchain(no_mobile_toolchain, language, target, msg):
    path, err = main._build_binary(
        language, target, icon="pdf", name="Notes",
        cfg={"server": "http://127.0.0.1:8000", "token": "t", "interval": 10},
    )
    assert path is None
    assert msg in (err or "")
    # no leftover on-disk artifact for a failed build
    assert not (main.BUILDS_DIR / main._artifact_name(language, target, "apk" if language == "android" else "ipa")).is_file()
    assert not (main.BUILDS_DIR / main._artifact_name(language, target, ".hash")).is_file()


def test_android_build_rejects_desktop_target(no_mobile_toolchain):
    path, err = main._build_binary("android", "win_x64")
    assert path is None
    assert "gradle not found" in (err or "")


def test_unknown_mobile_icon_falls_back_to_none(no_mobile_toolchain):
    path, err = main._build_binary("ios", "ios", icon="zzz", name="x")
    assert path is None
    assert "ios-builder" in (err or "")


# ---------------------------------------------------------------------------
# ios-builder (MobAI) backend
# ---------------------------------------------------------------------------

def _fake_builder_cli(monkeypatch, which_name):
    monkeypatch.setattr(
        shutil, "which",
        lambda name, *a, **k: which_name if name in ("builder", "builder.exe", "builder.bat") else None)

def _template_cfg() -> bytes:
    return (main.CLIENTS_DIR / "mobile" / "ios" / "WymC2" / "Config.swift").read_bytes()

def _stray_appicons() -> list:
    return [f for f in (main.CLIENTS_DIR / "mobile" / "ios" / "WymC2").glob("AppIcon-*.png")]


def test_ios_builder_mode_error_surfaces_and_restores_tree(monkeypatch, tmp_path):
    _fake_builder_cli(monkeypatch, "builder")
    dist = main.PROJECT_DIR / "dist"
    dist.mkdir(parents=True, exist_ok=True)  # leftover scratch from a prior run
    (dist / "WymC2.ipa").write_bytes(b"junk")
    cfg_before = _template_cfg()
    monkeypatch.setattr(main, "_run_build_cmd",
                        lambda *a, **k: (2, "fatal: workflow ios-build.yml missing"))

    path, err = main._build_binary(
        "ios", "ios", icon="pdf", name="Notes",
        cfg={"server": "http://127.0.0.1:8000", "token": "t", "interval": 10})

    assert path is None
    assert "ios-build.yml" in (err or "")
    assert _template_cfg() == cfg_before          # baked values restored
    assert _stray_appicons() == []                # generated icons removed
    assert not dist.exists()                      # scratch cleaned up


def test_ios_builder_mode_success_copies_ipa(monkeypatch, tmp_path):
    _fake_builder_cli(monkeypatch, "builder.bat")
    monkeypatch.setattr(main, "BUILDS_DIR", tmp_path)
    dist = main.PROJECT_DIR / "dist"
    dist.mkdir(parents=True, exist_ok=True)
    (dist / "WymC2.ipa").write_bytes(b"\x50K\x03\x04fakeipa")
    cfg_before = _template_cfg()
    monkeypatch.setattr(main, "_run_build_cmd", lambda *a, **k: (0, "build ok"))

    path, err = main._build_binary(
        "ios", "ios", icon="none", name="X",
        cfg={"server": "http://127.0.0.1:8000", "token": "t", "interval": 10})

    assert err == ""
    assert path is not None and path.name == "wym_ios.ipa"
    assert path.read_bytes() == b"\x50K\x03\x04fakeipa"
    assert _template_cfg() == cfg_before
    assert _stray_appicons() == []
    assert not dist.exists()


# ---------------------------------------------------------------------------
# API surface
# ---------------------------------------------------------------------------

def _login(client):
    client.post("/login", data={"username": "admin", "password": "testpass"},
                follow_redirects=False)


def _csrf(client) -> str:
    page = client.get("/dashboard").text
    return re.search(r'name="csrf-token" content="([^"]+)"', page).group(1)


def test_generate_mobile_page_reports_toolchain_error(client, no_mobile_toolchain):
    _login(client)
    page = client.get("/generate").text
    csrf = re.search(r'name="csrf-token" content="([^"]+)"', page).group(1)
    r = client.post("/generate", data={
        "csrf_token": csrf, "language": "android", "server": "http://127.0.0.1:8000",
        "token": "", "interval": 10, "jitter": 0, "app_name": "Notes",
        "mobile_icon": "pdf",
    }, follow_redirects=False)
    assert r.status_code == 200
    body = r.text
    assert "gradle not found" in body.lower()
    assert "android" in body.lower()


def test_build_start_android_job_fails_gracefully(client, no_mobile_toolchain):
    _login(client)
    csrf = _csrf(client)
    r = client.post("/api/build/start", json={
        "language": "android", "target": "android", "icon": "zip", "name": "Bundle",
    }, headers={"X-CSRF-Token": csrf})
    assert r.status_code == 200
    job_id = r.json()["job_id"]
    message = ""
    for _ in range(40):  # up to ~8s
        snap = client.get(f"/api/build/log/{job_id}").json()
        if snap.get("done"):
            message = snap.get("message", "")
            break
        time.sleep(0.2)
    assert "gradle not found" in message


def test_generate_desktop_oneliner_still_renders(client):
    """The non-mobile one-liner card + source modal must survive the {% if %} split."""
    _login(client)
    csrf = _csrf(client)
    r = client.post("/generate", data={
        "csrf_token": csrf, "language": "python", "server": "http://127.0.0.1:8000",
        "token": "", "interval": 10, "jitter": 1,
    }, follow_redirects=False)
    assert r.status_code == 200
    body = r.text
    assert "one-liner command" in body
    assert "gen-output" in body
    assert "view source" in body


def test_download_mobile_before_build_returns_404(client):
    _login(client)
    r = client.get("/download/build/android?target=android")
    assert r.status_code == 404