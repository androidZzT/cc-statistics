#!/usr/bin/env python3
"""Generate all Clawd pixel sprite PNGs using Pillow.

Each sprite is drawn at 36x36 (@2x) then downscaled to 18x18 (@1x) with NEAREST.
Transparent background, pixel-art style.
"""

from PIL import Image, ImageDraw
import os

OUTPUT_DIR = os.path.join(
    os.path.dirname(os.path.dirname(os.path.abspath(__file__))),
    "cc_stats_app", "swift", "Resources", "clawd",
)
SIZE_2X = 36
SIZE_1X = 18

# ── Colour palette ──────────────────────────────────────────────────────────
BODY = "#FF7043"
BODY_LIGHT = "#FF8A65"
BODY_DARK = "#E64A19"
SKIN = "#FFCCBC"
EYE = "#4E342E"
MOUTH = "#4E342E"
ZZZ_COLOR = "#90CAF9"
QUESTION_COLOR = "#CE93D8"
DOTS_COLOR = "#80DEEA"
ERROR_BODY = "#BF360C"
ERROR_DARK = "#870000"
RED_ACCENT = "#FF1744"
KB_KEY = "#546E7A"
KB_LIGHT = "#78909C"
WHITE = "#FFFFFF"
SMOKE = "#9E9E9E"


def save_sprite(img, name):
    os.makedirs(OUTPUT_DIR, exist_ok=True)
    img.save(os.path.join(OUTPUT_DIR, f"{name}@2x.png"))
    img_1x = img.resize((SIZE_1X, SIZE_1X), Image.NEAREST)
    img_1x.save(os.path.join(OUTPUT_DIR, f"{name}.png"))
    print(f"  {name}.png (18x18) + @2x (36x36)")


def px(d, x, y, color, size=1):
    """Draw a pixel block at (x, y) with given size."""
    d.rectangle([x, y, x + size - 1, y + size - 1], fill=color)


def draw_base_body(d, offset_y=0, lean=0, body_color=BODY,
                   light_color=BODY_LIGHT, dark_color=BODY_DARK):
    """Draw Clawd's base body shape. Returns nothing, draws on d."""
    ox = lean
    oy = offset_y

    # Ears/antennae
    px(d, 11 + ox, 2 + oy, body_color, 2)  # left ear
    px(d, 23 + ox, 2 + oy, body_color, 2)  # right ear
    px(d, 12 + ox, 4 + oy, body_color, 2)  # left ear stem
    px(d, 22 + ox, 4 + oy, body_color, 2)  # right ear stem

    # Head (wide oval)
    d.rectangle([10 + ox, 6 + oy, 25 + ox, 7 + oy], fill=body_color)  # top
    d.rectangle([8 + ox, 8 + oy, 27 + ox, 9 + oy], fill=body_color)   # wider
    d.rectangle([7 + ox, 10 + oy, 28 + ox, 19 + oy], fill=body_color) # main head
    d.rectangle([8 + ox, 20 + oy, 27 + ox, 21 + oy], fill=body_color) # chin

    # Highlight on forehead
    d.rectangle([10 + ox, 10 + oy, 14 + ox, 11 + oy], fill=light_color)

    # Body (torso)
    d.rectangle([10 + ox, 22 + oy, 25 + ox, 27 + oy], fill=body_color)

    # Belly highlight
    d.rectangle([14 + ox, 23 + oy, 21 + ox, 26 + oy], fill=SKIN)

    # Feet
    d.rectangle([9 + ox, 28 + oy, 14 + ox, 30 + oy], fill=dark_color)   # left foot
    d.rectangle([21 + ox, 28 + oy, 26 + ox, 30 + oy], fill=dark_color)  # right foot


def draw_eyes_half_closed(d, offset_y=0, lean=0):
    """Half-closed eyes: horizontal slits (drowsy)."""
    ox, oy = lean, offset_y
    # Left eye: horizontal line 4px wide
    d.rectangle([10 + ox, 15 + oy, 14 + ox, 16 + oy], fill=EYE)
    # Right eye
    d.rectangle([21 + ox, 15 + oy, 25 + ox, 16 + oy], fill=EYE)


def draw_eyes_closed(d, offset_y=0, lean=0):
    """Fully closed eyes: curved arcs (sleeping)."""
    ox, oy = lean, offset_y
    # Left eye: ◡ arc
    px(d, 10 + ox, 14 + oy, EYE, 1)
    px(d, 14 + ox, 14 + oy, EYE, 1)
    d.rectangle([11 + ox, 15 + oy, 13 + ox, 15 + oy], fill=EYE)
    # Right eye: ◡ arc
    px(d, 21 + ox, 14 + oy, EYE, 1)
    px(d, 25 + ox, 14 + oy, EYE, 1)
    d.rectangle([22 + ox, 15 + oy, 24 + ox, 15 + oy], fill=EYE)


def draw_eyes_open(d, offset_y=0, lean=0, look_up=False):
    """Big open eyes: 3x3 blocks."""
    ox, oy = lean, offset_y
    eye_y = 13 if look_up else 14
    # Left eye
    d.rectangle([10 + ox, eye_y + oy, 13 + ox, eye_y + 2 + oy], fill=EYE)
    # pupil highlight
    px(d, 10 + ox, eye_y + oy, WHITE, 1)
    # Right eye
    d.rectangle([22 + ox, eye_y + oy, 25 + ox, eye_y + 2 + oy], fill=EYE)
    px(d, 22 + ox, eye_y + oy, WHITE, 1)


def draw_eyes_x(d, offset_y=0, lean=0, color=RED_ACCENT):
    """X-shaped eyes for error/deep think."""
    ox, oy = lean, offset_y
    # Left X eye
    for i in range(4):
        px(d, 10 + i + ox, 13 + i + oy, color, 1)
        px(d, 13 - i + ox, 13 + i + oy, color, 1)
    # Right X eye
    for i in range(4):
        px(d, 21 + i + ox, 13 + i + oy, color, 1)
        px(d, 24 - i + ox, 13 + i + oy, color, 1)


def draw_mouth_sleepy(d, offset_y=0, lean=0):
    """Small curved mouth for drowsy state."""
    ox, oy = lean, offset_y
    d.rectangle([16 + ox, 19 + oy, 19 + ox, 19 + oy], fill=MOUTH)


def draw_mouth_open(d, offset_y=0, lean=0):
    """Open mouth (snoring/yawning)."""
    ox, oy = lean, offset_y
    d.rectangle([16 + ox, 19 + oy, 19 + ox, 19 + oy], fill=MOUTH)
    d.rectangle([15 + ox, 20 + oy, 20 + ox, 21 + oy], fill=MOUTH)
    d.rectangle([16 + ox, 20 + oy, 19 + ox, 20 + oy], fill="#8D6E63")  # tongue


def draw_mouth_grin(d, offset_y=0, lean=0):
    """Wide grin for happy/typing state."""
    ox, oy = lean, offset_y
    d.rectangle([14 + ox, 19 + oy, 21 + ox, 19 + oy], fill=MOUTH)
    px(d, 13 + ox, 18 + oy, MOUTH, 1)
    px(d, 22 + ox, 18 + oy, MOUTH, 1)


def draw_mouth_sad(d, offset_y=0, lean=0):
    """Frown for error state."""
    ox, oy = lean, offset_y
    d.rectangle([14 + ox, 20 + oy, 21 + ox, 20 + oy], fill=MOUTH)
    px(d, 13 + ox, 19 + oy, MOUTH, 1)
    px(d, 22 + ox, 19 + oy, MOUTH, 1)


def draw_arms_down(d, offset_y=0, lean=0, color=BODY_DARK):
    """Arms hanging down naturally."""
    ox, oy = lean, offset_y
    # Left arm
    d.rectangle([5 + ox, 22 + oy, 8 + ox, 27 + oy], fill=color)
    # Right arm
    d.rectangle([27 + ox, 22 + oy, 30 + ox, 27 + oy], fill=color)


def draw_arms_typing(d, offset_y=0, color=BODY_DARK):
    """Arms stretched forward (typing)."""
    # Left arm forward
    d.rectangle([7, 22 + offset_y, 10, 24 + offset_y], fill=color)
    d.rectangle([5, 25 + offset_y, 10, 26 + offset_y], fill=color)
    # Right arm forward
    d.rectangle([25, 22 + offset_y, 28, 24 + offset_y], fill=color)
    d.rectangle([25, 25 + offset_y, 30, 26 + offset_y], fill=color)


def draw_arm_chin(d, offset_y=0, lean=0):
    """Right arm raised to chin (thinking pose)."""
    ox, oy = lean, offset_y
    # Left arm down
    d.rectangle([5 + ox, 22 + oy, 8 + ox, 27 + oy], fill=BODY_DARK)
    # Right arm up to chin
    d.rectangle([27 + ox, 18 + oy, 30 + ox, 20 + oy], fill=BODY_DARK)
    d.rectangle([28 + ox, 21 + oy, 30 + ox, 24 + oy], fill=BODY_DARK)


def draw_arms_head(d, offset_y=0, lean=0):
    """Both arms raised to head (overwhelmed/deep think)."""
    ox, oy = lean, offset_y
    # Left arm up
    d.rectangle([5 + ox, 10 + oy, 8 + ox, 12 + oy], fill=BODY_DARK)
    d.rectangle([6 + ox, 13 + oy, 8 + ox, 22 + oy], fill=BODY_DARK)
    # Right arm up
    d.rectangle([27 + ox, 10 + oy, 30 + ox, 12 + oy], fill=BODY_DARK)
    d.rectangle([27 + ox, 13 + oy, 29 + ox, 22 + oy], fill=BODY_DARK)


# ── Frame generators ────────────────────────────────────────────────────────

def draw_idle_doze():
    """Clawd dozing: half-closed eyes, normal position, arms down."""
    img = Image.new("RGBA", (SIZE_2X, SIZE_2X), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    draw_base_body(d)
    draw_eyes_half_closed(d)
    draw_mouth_sleepy(d)
    draw_arms_down(d)

    save_sprite(img, "clawd-idle-doze")


def draw_sleeping():
    """Clawd sleeping: head drooped, closed eyes, open mouth, big ZZZ."""
    img = Image.new("RGBA", (SIZE_2X, SIZE_2X), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Body shifted down 3px for drooping effect
    draw_base_body(d, offset_y=3)
    draw_eyes_closed(d, offset_y=3)
    draw_mouth_open(d, offset_y=3)
    draw_arms_down(d, offset_y=3)

    # Big Z at top-right (rows 1-8, cols 26-33 → clamp to 35)
    z = ZZZ_COLOR
    # Large Z (7px wide)
    for x in range(28, 35):
        px(d, x, 1, z, 1)     # top bar
        px(d, x, 7, z, 1)     # bottom bar
    # Diagonal
    px(d, 34, 2, z, 1)
    px(d, 33, 3, z, 1)
    px(d, 32, 3, z, 1)
    px(d, 31, 4, z, 1)
    px(d, 30, 4, z, 1)
    px(d, 29, 5, z, 1)
    px(d, 28, 6, z, 1)

    # Medium z (5px wide, offset)
    for x in range(30, 35):
        px(d, x, 9, z, 1)     # top bar
        px(d, x, 13, z, 1)    # bottom bar
    px(d, 34, 10, z, 1)
    px(d, 33, 11, z, 1)
    px(d, 32, 11, z, 1)
    px(d, 31, 12, z, 1)
    px(d, 30, 12, z, 1)

    # Small z (3px wide)
    for x in range(33, 36):
        px(d, x, 15, z, 1)
        px(d, x, 17, z, 1)
    px(d, 34, 16, z, 1)
    px(d, 33, 16, z, 1)

    save_sprite(img, "clawd-sleeping")


def draw_working_typing():
    """Clawd typing: big eyes, grin, arms forward, keyboard below."""
    img = Image.new("RGBA", (SIZE_2X, SIZE_2X), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    draw_base_body(d)
    draw_eyes_open(d)
    draw_mouth_grin(d)
    draw_arms_typing(d)

    # Keyboard at bottom (rows 31-34)
    # Key row 1
    for x in range(6, 30, 4):
        d.rectangle([x, 31, x + 3, 33], fill=KB_KEY)
        px(d, x + 1, 31, KB_LIGHT, 1)  # key highlight
    # Key row 2 (offset)
    for x in range(8, 28, 4):
        d.rectangle([x, 33, x + 3, 35], fill=KB_KEY)
        px(d, x + 1, 33, KB_LIGHT, 1)

    save_sprite(img, "clawd-working-typing")


def draw_working_thinking():
    """Clawd thinking: lean left, eyes look up, hand on chin, ? symbol."""
    img = Image.new("RGBA", (SIZE_2X, SIZE_2X), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    lean = -2  # lean left
    draw_base_body(d, lean=lean)
    draw_eyes_open(d, lean=lean, look_up=True)
    draw_mouth_sleepy(d, lean=lean)
    draw_arm_chin(d, lean=lean)

    # Question mark ? at top-right (pixel art, ~5x8)
    q = QUESTION_COLOR
    # Top curve of ?
    for x in range(28, 33):
        px(d, x, 2, q, 1)
    px(d, 27, 3, q, 1)
    px(d, 33, 3, q, 1)
    px(d, 33, 4, q, 1)
    px(d, 32, 5, q, 1)
    px(d, 31, 6, q, 1)
    px(d, 30, 7, q, 1)
    px(d, 30, 8, q, 1)
    # Dot of ?
    px(d, 30, 10, q, 1)
    px(d, 30, 11, q, 1)

    save_sprite(img, "clawd-working-thinking")


def draw_working_ultrathink():
    """Clawd ultra-thinking: lean right, spiral/X eyes, arms on head, ! symbol."""
    img = Image.new("RGBA", (SIZE_2X, SIZE_2X), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    lean = 2  # lean right (opposite of thinking)
    draw_base_body(d, lean=lean)

    # Spiral-like eyes (concentric pattern)
    ox, oy = lean, 0
    # Left eye: spiral approximation
    d.rectangle([10 + ox, 13 + oy, 14 + ox, 17 + oy], fill=DOTS_COLOR)
    d.rectangle([11 + ox, 14 + oy, 13 + ox, 16 + oy], fill=BODY)
    px(d, 12 + ox, 15 + oy, DOTS_COLOR, 1)  # center dot

    # Right eye: spiral approximation
    d.rectangle([21 + ox, 13 + oy, 25 + ox, 17 + oy], fill=DOTS_COLOR)
    d.rectangle([22 + ox, 14 + oy, 24 + ox, 16 + oy], fill=BODY)
    px(d, 23 + ox, 15 + oy, DOTS_COLOR, 1)  # center dot

    draw_mouth_sleepy(d, lean=lean)
    draw_arms_head(d, lean=lean)

    # Three dots ... and ! at top-left
    dot = DOTS_COLOR
    # Three dots
    px(d, 2, 4, dot, 2)
    px(d, 6, 3, dot, 2)
    px(d, 10, 2, dot, 2)

    # Exclamation ! at top
    d.rectangle([1, 7, 2, 11], fill=DOTS_COLOR)
    px(d, 1, 13, DOTS_COLOR, 2)

    save_sprite(img, "clawd-working-ultrathink")


def draw_error():
    """Clawd error: dark body, X eyes, frown, smoke/! above."""
    img = Image.new("RGBA", (SIZE_2X, SIZE_2X), (0, 0, 0, 0))
    d = ImageDraw.Draw(img)

    # Body shifted down 2px (sinking)
    draw_base_body(d, offset_y=2, body_color=ERROR_BODY,
                   light_color=ERROR_BODY, dark_color=ERROR_DARK)
    draw_eyes_x(d, offset_y=2)
    draw_mouth_sad(d, offset_y=2)
    draw_arms_down(d, offset_y=2, color=ERROR_DARK)

    # Red exclamation ! at top-center
    d.rectangle([16, 0, 19, 1], fill=RED_ACCENT)
    d.rectangle([16, 2, 19, 6], fill=RED_ACCENT)
    px(d, 16, 8, RED_ACCENT, 2)
    px(d, 18, 8, RED_ACCENT, 2)

    # Smoke puffs at top-left and top-right
    s = SMOKE
    # Left puff
    px(d, 4, 2, s, 2)
    px(d, 3, 4, s, 2)
    px(d, 6, 3, s, 2)
    # Right puff
    px(d, 28, 1, s, 2)
    px(d, 30, 3, s, 2)
    px(d, 27, 4, s, 2)

    save_sprite(img, "clawd-error")


# ── Main ────────────────────────────────────────────────────────────────────

def main():
    print("Generating Clawd sprites...")
    draw_idle_doze()
    draw_sleeping()
    draw_working_typing()
    draw_working_thinking()
    draw_working_ultrathink()
    draw_error()
    print(f"\nAll 12 sprites written to {OUTPUT_DIR}")


if __name__ == "__main__":
    main()
