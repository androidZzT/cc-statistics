from __future__ import annotations

import struct
import zlib
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
TAURI_DIR = ROOT / "desktop" / "cc-stats-tauri" / "src-tauri"


def _png_unique_rgba_colors(path: Path) -> set[tuple[int, int, int, int]]:
    data = path.read_bytes()
    assert data.startswith(b"\x89PNG\r\n\x1a\n")

    offset = 8
    width = height = color_type = None
    compressed = bytearray()
    while offset < len(data):
        length = int.from_bytes(data[offset : offset + 4], "big")
        chunk_type = data[offset + 4 : offset + 8]
        chunk_data = data[offset + 8 : offset + 8 + length]
        offset += 12 + length

        if chunk_type == b"IHDR":
            width, height, bit_depth, color_type = struct.unpack(">IIBB", chunk_data[:10])
            assert bit_depth == 8
            assert color_type == 6
        elif chunk_type == b"IDAT":
            compressed.extend(chunk_data)
        elif chunk_type == b"IEND":
            break

    assert width is not None
    assert height is not None
    assert color_type == 6

    raw = zlib.decompress(bytes(compressed))
    row_stride = width * 4
    colors: set[tuple[int, int, int, int]] = set()
    pos = 0
    previous = bytearray(row_stride)
    for _ in range(height):
        filter_type = raw[pos]
        pos += 1
        row = bytearray(raw[pos : pos + row_stride])
        pos += row_stride

        if filter_type == 1:
            for i, value in enumerate(row):
                row[i] = (value + (row[i - 4] if i >= 4 else 0)) & 0xFF
        elif filter_type == 2:
            for i, value in enumerate(row):
                row[i] = (value + previous[i]) & 0xFF
        elif filter_type == 3:
            for i, value in enumerate(row):
                left = row[i - 4] if i >= 4 else 0
                row[i] = (value + ((left + previous[i]) // 2)) & 0xFF
        elif filter_type == 4:
            for i, value in enumerate(row):
                left = row[i - 4] if i >= 4 else 0
                up = previous[i]
                up_left = previous[i - 4] if i >= 4 else 0
                p = left + up - up_left
                pa = abs(p - left)
                pb = abs(p - up)
                pc = abs(p - up_left)
                predictor = left if pa <= pb and pa <= pc else up if pb <= pc else up_left
                row[i] = (value + predictor) & 0xFF
        else:
            assert filter_type == 0

        for i in range(0, row_stride, 4):
            colors.add(tuple(row[i : i + 4]))
            if len(colors) > 8:
                return colors
        previous = row
    return colors


def test_windows_release_uses_gui_subsystem() -> None:
    main_rs = (TAURI_DIR / "src" / "main.rs").read_text(encoding="utf-8")

    assert 'windows_subsystem = "windows"' in main_rs


def test_python_api_child_process_uses_no_window_flag() -> None:
    api_process_rs = (TAURI_DIR / "src" / "api_process.rs").read_text(encoding="utf-8")

    assert "CREATE_NO_WINDOW" in api_process_rs
    assert "creation_flags" in api_process_rs


def test_tray_uses_explicit_default_window_icon() -> None:
    tray_rs = (TAURI_DIR / "src" / "tray.rs").read_text(encoding="utf-8")

    assert ".icon(" in tray_rs
    assert "default_window_icon" in tray_rs


def test_tray_open_dashboard_uses_external_dashboard_command() -> None:
    tray_rs = (TAURI_DIR / "src" / "tray.rs").read_text(encoding="utf-8")

    assert "open_dashboard_for_app" in tray_rs
    assert 'event.id.as_ref() {\n            "open_dashboard" => {\n                let _ = window::show_dashboard_window(app);' not in tray_rs


def test_tray_quit_stops_api_before_app_exit() -> None:
    main_rs = (TAURI_DIR / "src" / "main.rs").read_text(encoding="utf-8")
    tray_rs = (TAURI_DIR / "src" / "tray.rs").read_text(encoding="utf-8")

    assert "pub fn quit_app" in main_rs
    assert "api.stop();" in main_rs
    assert "quit_app(app);" in tray_rs
    assert '"quit" => {\n                app.exit(0);' not in tray_rs


def test_python_api_bundles_python_sources_as_tauri_resources() -> None:
    config = (TAURI_DIR / "tauri.conf.json").read_text(encoding="utf-8")

    assert "../../../cc_stats" in config
    assert "../../../cc_stats_web" in config
    assert "python/cc_stats" in config
    assert "python/cc_stats_web" in config


def test_python_api_child_process_uses_bundled_pythonpath() -> None:
    api_process_rs = (TAURI_DIR / "src" / "api_process.rs").read_text(encoding="utf-8")

    assert "PYTHONPATH" in api_process_rs
    assert "python_source_dir" in api_process_rs


def test_tray_icon_assets_are_multi_size_and_non_monochrome() -> None:
    icon_png = TAURI_DIR / "icons" / "icon.png"
    icon_ico = TAURI_DIR / "icons" / "icon.ico"

    assert len(_png_unique_rgba_colors(icon_png)) > 1

    data = icon_ico.read_bytes()
    reserved, kind, count = struct.unpack("<HHH", data[:6])
    assert reserved == 0
    assert kind == 1
    assert count >= 4
