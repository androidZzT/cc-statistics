#!/usr/bin/env python3
"""Generate all Clawd pixel sprite PNGs using only stdlib (struct + zlib).

Each sprite is 18x18 @1x and 36x36 @2x, RGBA with transparent background.
"""

import os
import struct
import zlib

# ── Colour palette ──────────────────────────────────────────────────────────
T = (0, 0, 0, 0)  # transparent
BODY = (0xF0, 0x95, 0x6B, 255)  # #F0956B  main body
BODY_DARK = (0xC0, 0x60, 0x40, 255)  # #C06040  error body / shadow
OUTLINE = (0x3D, 0x1C, 0x08, 255)  # #3D1C08  outline / eyes
EYE = OUTLINE
HIGHLIGHT = (0xFF, 0xB8, 0x99, 255)  # #FFB899  highlight
ZZZ = (0xAA, 0xDD, 0xFF, 255)  # #AADDFF  sleep z
BULB = (0xFF, 0xDD, 0x44, 255)  # #FFDD44  lightbulb
DOTS = (0x99, 0x99, 0x99, 255)  # thinking dots
RED_X = (0xCC, 0x00, 0x00, 255)  # error x-eyes
KB_KEY = (0x66, 0x66, 0x88, 255)  # keyboard keys
WHITE = (0xFF, 0xFF, 0xFF, 255)
MOUTH = (0x8B, 0x45, 0x13, 255)  # mouth

# ── PNG writer (pure stdlib) ────────────────────────────────────────────────

def _make_png(width: int, height: int, pixels: list[list[tuple]]) -> bytes:
    """Create a PNG file from a 2D list of (R, G, B, A) tuples."""
    raw = b""
    for row in pixels:
        raw += b"\x00"  # filter byte: None
        for r, g, b, a in row:
            raw += struct.pack("BBBB", r, g, b, a)

    def _chunk(ctype: bytes, data: bytes) -> bytes:
        c = ctype + data
        return struct.pack(">I", len(data)) + c + struct.pack(">I", zlib.crc32(c) & 0xFFFFFFFF)

    sig = b"\x89PNG\r\n\x1a\n"
    ihdr = _chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
    idat = _chunk(b"IDAT", zlib.compress(raw, 9))
    iend = _chunk(b"IEND", b"")
    return sig + ihdr + idat + iend


def _scale2x(pixels: list[list[tuple]]) -> list[list[tuple]]:
    """Double each pixel to 2x2 block."""
    out = []
    for row in pixels:
        scaled_row = []
        for px in row:
            scaled_row.extend([px, px])
        out.append(scaled_row)
        out.append(list(scaled_row))
    return out


# ── Base body template (18x18) ──────────────────────────────────────────────
# The base body occupies roughly rows 3-15, cols 4-13 of an 18x18 grid.
# We'll build each frame by composing a body + eyes + decorations.

def _blank(w: int = 18, h: int = 18) -> list[list[tuple]]:
    return [[T] * w for _ in range(h)]


def _draw_body(grid: list[list[tuple]], color: tuple = BODY,
               shift_down: int = 0, lean: int = 0) -> None:
    """Draw Clawd's body shape onto grid. lean: -1=left, 0=center, 1=right."""
    # Body shape rows (relative to row 4+shift_down)
    # Clawd is a roundish blob with two small ear/antenna bumps
    body_rows = [
        # row 0: antennae tips
        (6, 7, 11, 12),
        # row 1: antennae stems
        (6, 7, 11, 12),
        # row 2: head top
        (5, 6, 7, 8, 9, 10, 11, 12),
        # row 3: head
        (4, 5, 6, 7, 8, 9, 10, 11, 12, 13),
        # row 4: face area
        (4, 5, 6, 7, 8, 9, 10, 11, 12, 13),
        # row 5: face area
        (4, 5, 6, 7, 8, 9, 10, 11, 12, 13),
        # row 6: face lower
        (4, 5, 6, 7, 8, 9, 10, 11, 12, 13),
        # row 7: body
        (5, 6, 7, 8, 9, 10, 11, 12),
        # row 8: body lower
        (5, 6, 7, 8, 9, 10, 11, 12),
        # row 9: feet
        (5, 6, 7, 11, 12, 13),
    ]
    base_r = 4 + shift_down
    for i, cols in enumerate(body_rows):
        r = base_r + i
        if 0 <= r < len(grid):
            for c in cols:
                cc = c + lean
                if 0 <= cc < len(grid[0]):
                    grid[r][cc] = color

    # Add outline pixels (top, bottom edges)
    outline_rows = [
        # top of head
        (3 + shift_down, (7, 8, 9, 10)),
        # bottom feet connectors
        (14 + shift_down, (5, 6, 7, 11, 12, 13)),
    ]
    for r, cols in outline_rows:
        if 0 <= r < len(grid):
            for c in cols:
                cc = c + lean
                if 0 <= cc < len(grid[0]):
                    grid[r][cc] = OUTLINE

    # Add highlight on forehead
    hl_r = 6 + shift_down
    if 0 <= hl_r < len(grid):
        for c in (6, 7):
            cc = c + lean
            if 0 <= cc < len(grid[0]):
                grid[hl_r][cc] = HIGHLIGHT


def _draw_eyes_open(grid: list[list[tuple]], shift_down: int = 0,
                    lean: int = 0, pupil_offset: int = 0) -> None:
    """Draw open eyes (2x2 blocks). pupil_offset: -1=look left, 1=look right."""
    eye_r = 8 + shift_down
    left_eye_c = 6 + lean + pupil_offset
    right_eye_c = 11 + lean + pupil_offset
    for r in (eye_r, eye_r + 1):
        if 0 <= r < len(grid):
            for c in (left_eye_c, left_eye_c + 1, right_eye_c, right_eye_c + 1):
                if 0 <= c < len(grid[0]):
                    grid[r][c] = EYE


def _draw_eyes_half_closed(grid: list[list[tuple]], shift_down: int = 0,
                           lean: int = 0) -> None:
    """Draw half-closed eyes as 3px-wide horizontal slits for dozing look."""
    eye_r = 9 + shift_down
    h = len(grid)
    w = len(grid[0]) if h > 0 else 0
    if 0 <= eye_r < h:
        # Left eye: 3px wide slit at cols 5-7
        for c in (5, 6, 7):
            cc = c + lean
            if 0 <= cc < w:
                grid[eye_r][cc] = EYE
        # Right eye: 3px wide slit at cols 10-12
        for c in (10, 11, 12):
            cc = c + lean
            if 0 <= cc < w:
                grid[eye_r][cc] = EYE


def _draw_eyes_closed(grid: list[list[tuple]], shift_down: int = 0,
                      lean: int = 0) -> None:
    """Draw closed eyes as deep ◡ arcs (5px wide, 3 rows tall for @2x visibility)."""
    eye_r = 8 + shift_down
    h = len(grid)
    w = len(grid[0]) if h > 0 else 0

    def _put(r: int, c: int) -> None:
        c += lean
        if 0 <= r < h and 0 <= c < w:
            grid[r][c] = EYE

    # Left eye ◡ (5px wide, 3 rows): deep U-curve
    # Row 0: corners          Row 1: sides          Row 2: bottom center
    _put(eye_r, 5)           # top-left corner
    _put(eye_r, 8)           # top-right corner
    _put(eye_r + 1, 5)      # left side
    _put(eye_r + 1, 8)      # right side
    _put(eye_r + 2, 6)      # bottom-left
    _put(eye_r + 2, 7)      # bottom-right

    # Right eye ◡ (5px wide, 3 rows)
    _put(eye_r, 10)
    _put(eye_r, 13)
    _put(eye_r + 1, 10)
    _put(eye_r + 1, 13)
    _put(eye_r + 2, 11)
    _put(eye_r + 2, 12)


def _draw_eyes_x(grid: list[list[tuple]], shift_down: int = 0,
                 lean: int = 0) -> None:
    """Draw X-shaped eyes for error state."""
    eye_r = 8 + shift_down
    # Left X
    for dr, dc in [(0, 0), (0, 1), (1, 0), (1, 1)]:
        r = eye_r + dr
        # X pattern: top-left & bottom-right, top-right & bottom-left
        if dr == dc or (dr == 0 and dc == 1) or (dr == 1 and dc == 0):
            c = 6 + dc + lean
            if 0 <= r < len(grid) and 0 <= c < len(grid[0]):
                grid[r][c] = RED_X
    # Right X
    for dr, dc in [(0, 0), (0, 1), (1, 0), (1, 1)]:
        r = eye_r + dr
        c = 11 + dc + lean
        if 0 <= r < len(grid) and 0 <= c < len(grid[0]):
            grid[r][c] = RED_X


def _draw_mouth_happy(grid: list[list[tuple]], shift_down: int = 0,
                      lean: int = 0) -> None:
    """Small smile."""
    r = 11 + shift_down
    if 0 <= r < len(grid):
        for c in (8, 9):
            cc = c + lean
            if 0 <= cc < len(grid[0]):
                grid[r][cc] = MOUTH


def _draw_mouth_sad(grid: list[list[tuple]], shift_down: int = 0,
                    lean: int = 0) -> None:
    """Frown (∩ shape)."""
    r = 11 + shift_down
    if 0 <= r < len(grid):
        for c in (8, 9):
            cc = c + lean
            if 0 <= cc < len(grid[0]):
                grid[r][cc] = RED_X
    r2 = 10 + shift_down
    if 0 <= r2 < len(grid):
        for c in (7, 10):
            cc = c + lean
            if 0 <= cc < len(grid[0]):
                grid[r2][cc] = RED_X


def _draw_mouth_o(grid: list[list[tuple]], shift_down: int = 0,
                  lean: int = 0) -> None:
    """Small O-shaped relaxed mouth for sleeping."""
    h = len(grid)
    w = len(grid[0]) if h > 0 else 0

    def _put(r: int, c: int) -> None:
        c += lean
        if 0 <= r < h and 0 <= c < w:
            grid[r][c] = MOUTH

    r = 11 + shift_down
    _put(r, 8)
    _put(r, 10)
    _put(r + 1, 9)
    _put(r - 1, 9)


# ── Frame generators ────────────────────────────────────────────────────────

def make_idle_doze() -> list[list[tuple]]:
    """Clawd dozing - half-closed eyes (— —), upright body, small star accent."""
    g = _blank()
    _draw_body(g, BODY, shift_down=0)
    _draw_eyes_half_closed(g, shift_down=0)
    _draw_mouth_happy(g, shift_down=0)

    # Small star/sparkle near right eye (about to doze off)
    g[7][14] = BULB  # tiny star accent
    g[6][15] = BULB

    return g


def make_sleeping() -> list[list[tuple]]:
    """Clawd sleeping - ◡ eyes, O mouth, body sunk+tilted right, prominent Zzz."""
    g = _blank()
    _draw_body(g, BODY, shift_down=4, lean=1)  # big droop + tilt right
    _draw_eyes_closed(g, shift_down=4, lean=1)
    _draw_mouth_o(g, shift_down=4, lean=1)

    # Small z (2x2) at rows 0-1, cols 14-15
    z = ZZZ
    g[0][14] = z; g[0][15] = z
    g[1][14] = z; g[1][15] = z

    # Medium Z (3x3) at rows 0-2, cols 15-17
    for c in (15, 16, 17):
        g[0][c] = z   # top bar
    g[1][16] = z       # diagonal
    for c in (15, 16, 17):
        g[2][c] = z   # bottom bar

    # Big Z (5x5) at rows 0-4, cols 13-17
    for c in (13, 14, 15, 16, 17):
        g[0][c] = z   # top bar
    g[1][16] = z; g[1][15] = z   # diagonal
    g[2][14] = z; g[2][15] = z
    g[3][13] = z; g[3][14] = z
    for c in (13, 14, 15, 16, 17):
        g[4][c] = z   # bottom bar

    return g


def make_working_typing() -> list[list[tuple]]:
    """Clawd typing - big open eyes, keyboard below."""
    g = _blank()
    _draw_body(g, BODY)
    _draw_eyes_open(g)
    _draw_mouth_happy(g)
    # Keyboard at bottom (rows 15-16)
    for r in (15, 16):
        for c in (4, 5, 7, 8, 10, 11, 13, 14):
            if 0 <= c < 18:
                g[r][c] = KB_KEY
    # Key highlights
    g[15][5] = WHITE
    g[16][10] = WHITE
    return g


def make_working_thinking() -> list[list[tuple]]:
    """Clawd thinking - lean forward, 3x3 eye frames pupils left, O mouth, bubbles left."""
    g = _blank()
    _draw_body(g, BODY, lean=-1)  # lean left (forward)

    lean = -1
    eye_r = 8
    # Left eye: 3x3 hollow frame at (8,5)-(10,7), pupil at left col
    for c in (5, 6, 7):
        cc = c + lean
        if 0 <= cc < 18:
            g[eye_r][cc] = EYE       # top edge
            g[eye_r + 2][cc] = EYE   # bottom edge
    for c in (5, 7):
        cc = c + lean
        if 0 <= cc < 18:
            g[eye_r + 1][cc] = EYE   # sides
    # Pupil at far left
    cc = 5 + lean
    if 0 <= cc < 18:
        g[eye_r + 1][cc] = EYE

    # Right eye: 3x3 hollow frame at (8,10)-(10,12), pupil at left col
    for c in (10, 11, 12):
        cc = c + lean
        if 0 <= cc < 18:
            g[eye_r][cc] = EYE
            g[eye_r + 2][cc] = EYE
    for c in (10, 12):
        cc = c + lean
        if 0 <= cc < 18:
            g[eye_r + 1][cc] = EYE
    cc = 10 + lean
    if 0 <= cc < 18:
        g[eye_r + 1][cc] = EYE

    # O-shaped mouth (focused expression)
    _draw_mouth_o(g, lean=lean)

    # Thought bubbles at LEFT upper corner: small→medium→large, from right-low to left-high
    g[6][3] = DOTS   # small dot (1px) near body
    # Medium dot (2x2)
    g[4][1] = DOTS; g[4][2] = DOTS
    g[5][1] = DOTS; g[5][2] = DOTS
    # Large dot (3x3)
    g[1][0] = DOTS; g[1][1] = DOTS; g[1][2] = DOTS
    g[2][0] = DOTS; g[2][1] = DOTS; g[2][2] = DOTS
    g[3][0] = DOTS; g[3][1] = DOTS; g[3][2] = DOTS

    return g


def make_working_ultrathink() -> list[list[tuple]]:
    """Clawd ultra-thinking - lean back+up, large ✦ star eyes, big O mouth, bulb at left."""
    g = _blank()
    _draw_body(g, BODY, shift_down=-1, lean=1)  # lean back and rise up

    sd = -1
    ln = 1
    # Large star/cross ✦ eyes in BULB yellow — 3x3 cross pattern for max visibility
    # Left eye center at (9+sd, 6+ln)
    cx1, cy1 = 9 + sd, 6 + ln
    # Full cross: center + 4 cardinal + 4 diagonal
    for dr, dc in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]:
        r, c = cx1 + dr, cy1 + dc
        if 0 <= r < 18 and 0 <= c < 18:
            g[r][c] = BULB
    for dr, dc in [(-1, -1), (-1, 1), (1, -1), (1, 1)]:
        r, c = cx1 + dr, cy1 + dc
        if 0 <= r < 18 and 0 <= c < 18:
            g[r][c] = BULB  # diagonals also yellow for bigger star

    # Right eye center at (9+sd, 12+ln)
    cx2, cy2 = 9 + sd, 12 + ln
    for dr, dc in [(0, 0), (-1, 0), (1, 0), (0, -1), (0, 1)]:
        r, c = cx2 + dr, cy2 + dc
        if 0 <= r < 18 and 0 <= c < 18:
            g[r][c] = BULB
    for dr, dc in [(-1, -1), (-1, 1), (1, -1), (1, 1)]:
        r, c = cx2 + dr, cy2 + dc
        if 0 <= r < 18 and 0 <= c < 18:
            g[r][c] = BULB

    # Big O mouth (excited)
    _draw_mouth_o(g, shift_down=sd, lean=ln)

    # Large lightbulb at LEFT upper corner: rows 0-4, cols 0-4
    b = BULB
    #   Row 0:  ·XXX·  (cols 1-3)
    g[0][1] = b; g[0][2] = b; g[0][3] = b
    #   Row 1: XXXXX  (cols 0-4)
    for c in range(5):
        g[1][c] = b
    #   Row 2: XXXXX  (cols 0-4)
    for c in range(5):
        g[2][c] = b
    #   Row 3:  ·XXX·  (cols 1-3)
    g[3][1] = b; g[3][2] = b; g[3][3] = b
    # Filament glow (white center)
    g[1][2] = WHITE; g[2][2] = WHITE
    # Base/screw
    g[4][1] = OUTLINE; g[4][2] = OUTLINE; g[4][3] = OUTLINE

    return g


def make_error() -> list[list[tuple]]:
    """Clawd error - X eyes, frown, darker body, red cross."""
    g = _blank()
    _draw_body(g, BODY_DARK)  # darker body
    _draw_eyes_x(g)
    _draw_mouth_sad(g)
    # Red cross/X at top-right corner
    for i in range(3):
        r1 = 1 + i
        c1 = 14 + i
        c2 = 16 - i
        if 0 <= c1 < 18:
            g[r1][c1] = RED_X
        if 0 <= c2 < 18:
            g[r1][c2] = RED_X
    return g


# ── Main ────────────────────────────────────────────────────────────────────

FRAMES = {
    "clawd-idle-doze": make_idle_doze,
    "clawd-sleeping": make_sleeping,
    "clawd-working-typing": make_working_typing,
    "clawd-working-thinking": make_working_thinking,
    "clawd-working-ultrathink": make_working_ultrathink,
    "clawd-error": make_error,
}


def main() -> None:
    out_dir = os.path.join(
        os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
        "cc_stats_app", "swift", "Resources", "clawd",
    )
    os.makedirs(out_dir, exist_ok=True)

    for name, gen_fn in FRAMES.items():
        pixels_1x = gen_fn()
        pixels_2x = _scale2x(pixels_1x)

        path_1x = os.path.join(out_dir, f"{name}.png")
        path_2x = os.path.join(out_dir, f"{name}@2x.png")

        with open(path_1x, "wb") as f:
            f.write(_make_png(18, 18, pixels_1x))
        with open(path_2x, "wb") as f:
            f.write(_make_png(36, 36, pixels_2x))

        print(f"  {name}.png (18x18) + @2x (36x36)")

    print(f"\nAll 12 sprites written to {out_dir}")


if __name__ == "__main__":
    main()
