#!/usr/bin/env python3
# SPDX-FileCopyrightText: 2026 amurcanov
# SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0

"""
CSQTT Canonical Version Lockup Generator
Single source of truth for version badge geometry across Android and Web Panel.

Design Canon Constants (184-unit canvas, shared with wordmark ic_csqtt_logo.xml):
- Viewport Height: 184 units (identical to wordmark)
- Optical Baseline: Y=157.5 (stroke centerline) -> ink bottom = 157.5 + 6.5 = 164.0 (identical to wordmark base)
- Cap-Height: 67.0 units (Y=90.5) -> stroke/cap ratio = 13/67 = 19.4% (matches wordmark stroke/cap ~20.1%)
- x-Height: 47.0 units (Y=110.5, ~70.1% of cap)
- Stroke Width: 13.0 units (half-stroke radius = 6.5)
- Tabular digit width: 44.0 units
- Rhythm / White Gaps: target regular white gap = 8.0 units (0.96 dp), gap before '1' = 10.5 units (1.26 dp)
- Symmetric Margins: left_pad = right_pad = 16.0 units
- Linear Gradient: axis (0,0 -> 68,340) matching wordmark; stops: #1E88FE, #1576FD, #0B5FFC, #0A5CFC
  (joint Delta <= 1 across entire height; worst-case WCAG contrast >= 3.14:1 on all theme surfaces)

Usage:
    python3 scripts/gen_version_lockup.py              # Updates assets based on app/build.gradle.kts
    python3 scripts/gen_version_lockup.py 2.5.1        # Updates assets for specified version
    python3 scripts/gen_version_lockup.py --check      # Verifies committed assets are in sync (exit 0 or 1)
"""

import argparse
import os
import re
import sys
from typing import List, Tuple

SCRIPT_DIR = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(SCRIPT_DIR)

GRADLE_FILE = os.path.join(REPO_ROOT, "app", "build.gradle.kts")
ANDROID_XML_FILE = os.path.join(REPO_ROOT, "app", "src", "main", "res", "drawable", "ic_version.xml")
WEB_PANEL_FILE = os.path.join(REPO_ROOT, "rust-server", "web_panel.rs")


# ==============================================================================
# 1. Canonical Constants
# ==============================================================================

VIEWPORT_HEIGHT = 184.0
STROKE_WIDTH = 13.0
HALF_STROKE = 6.5

# Defect 2 Fix: Centerline baseline at 157.5 -> ink bottom rests at 157.5 + 6.5 = 164.0
BASELINE_Y = 157.5

# Defect 1 Fix: Cap-height = 67.0 -> stroke/cap = 19.4% (matches wordmark 20.1%)
CAP_Y = 90.5
V_TOP_Y = 110.5   # x-height = 47.0 (~70.1% of cap)

DIGIT_WIDTH = 44.0
V_WIDTH = 40.0

# White gap model (distance between actual ink bounds)
TARGET_WHITE_GAP = 8.0   # 0.96 dp
GAP_BEFORE_ONE = 10.5    # 1.26 dp (strictly <= 12.0 units)
LEFT_PAD = 16.0          # Symmetric margin to viewport edge


def _fmt(v: float) -> str:
    s = f"{v:.2f}".rstrip("0").rstrip(".")
    return s if s else "0"


def _shift_subpath(subpath: str, dx: float) -> str:
    tokens = subpath.split()
    out = []
    i = 0
    cmd = ""
    while i < len(tokens):
        token = tokens[i]
        if token in "MLQHVZ":
            cmd = token
            out.append(token)
            i += 1
            continue
        if cmd in ("M", "L"):
            parts = token.split(",")
            x = float(parts[0]) + dx
            y = float(parts[1])
            out.append(f"{_fmt(x)},{_fmt(y)}")
            i += 1
        elif cmd == "H":
            x = float(token) + dx
            out.append(f"{_fmt(x)}")
            i += 1
        elif cmd == "V":
            out.append(token)
            i += 1
        elif cmd == "Q":
            parts1 = token.split(",")
            cx = float(parts1[0]) + dx
            cy = float(parts1[1])
            i += 1
            parts2 = tokens[i].split(",")
            x = float(parts2[0]) + dx
            y = float(parts2[1])
            out.append(f"{_fmt(cx)},{_fmt(cy)}")
            out.append(f"{_fmt(x)},{_fmt(y)}")
            i += 1
        elif cmd == "Z":
            out.append(token)
            i += 1
        else:
            out.append(token)
            i += 1
    return " ".join(out)


def get_glyph(ch: str) -> Tuple[float, float, List[str]]:
    """
    Returns (ink_start_x, ink_end_x, subpaths) at local origin (x=0).
    Coordinates are aligned to BASELINE_Y = 157.5 and CAP_Y = 90.5.
    """
    b = BASELINE_Y  # 157.5
    c = CAP_Y       # 90.5

    if ch == 'v':
        return (0.0, 40.0, [f"M 0,{V_TOP_Y} L 20,{b} L 40,{V_TOP_Y}"])

    if ch == '0':
        return (0.0, 44.0, [
            f"M 0,105 Q 0,{c} 22,{c} Q 44,{c} 44,105 V 143 Q 44,{b} 22,{b} Q 0,{b} 0,143 Z"
        ])

    if ch == '1':
        return (0.0, 16.0, [
            f"M 0,105 L 16,{c} V {b}"
        ])

    if ch == '2':
        return (0.0, 44.0, [
            f"M 0,104 Q 0,{c} 22,{c} Q 44,{c} 44,105 Q 44,120 32,130 L 0,{b} H 44"
        ])

    if ch == '3':
        return (0.0, 44.0, [
            f"M 0,102 Q 4,{c} 22,{c} Q 44,{c} 44,105 Q 44,118 30,123 Q 44,126 44,142 Q 44,{b} 22,{b} Q 0,{b} 0,145"
        ])

    if ch == '4':
        return (0.0, 44.0, [
            f"M 32,{b} V {c} L 0,128 H 44"
        ])

    if ch == '5':
        return (0.0, 44.0, [
            f"M 44,{c} H 0 V 118 H 22 Q 44,118 44,138 Q 44,{b} 22,{b} Q 0,{b} 0,145"
        ])

    if ch == '6':
        return (0.0, 44.0, [
            f"M 40,102 Q 32,{c} 22,{c} Q 0,{c} 0,124 Q 0,{b} 22,{b} Q 44,{b} 44,139 Q 44,119 22,119 Q 0,119 0,139"
        ])

    if ch == '7':
        return (0.0, 44.0, [
            f"M 0,{c} H 44 L 14,{b}"
        ])

    if ch == '8':
        return (0.0, 44.0, [
            f"M 22,{c} Q 0,{c} 0,105 Q 0,118 22,123 Q 44,126 44,141 Q 44,{b} 22,{b} Q 0,{b} 0,141 Q 0,126 22,123 Q 44,118 44,105 Q 44,{c} 22,{c} Z"
        ])

    if ch == '9':
        return (0.0, 44.0, [
            f"M 4,146 Q 12,{b} 22,{b} Q 44,{b} 44,124 Q 44,{c} 22,{c} Q 0,{c} 0,109 Q 0,129 22,129 Q 44,129 44,109"
        ])

    if ch == '.':
        return (0.0, 0.0, [f"M 0,{b} L 0.01,{b}"])

    raise ValueError(f"Unsupported character in version lockup: {ch!r}")


def render_lockup_geometry(version: str) -> Tuple[str, int, int, List[Tuple[str, float]]]:
    """
    Renders version string using the white gap layout model.
    Returns (path_d, viewport_width_int, dp_width_int, gap_measurements).
    """
    clean_ver = version.lstrip("v")
    text = f"v{clean_ver}"

    placed = []
    cur_x = LEFT_PAD

    for idx, ch in enumerate(text):
        x1, x2, paths = get_glyph(ch)
        if idx > 0:
            prev_ch, _, prev_x1, prev_x2, prev_ink_l, prev_ink_r = placed[-1]
            gap_w = GAP_BEFORE_ONE if ch == '1' else TARGET_WHITE_GAP
            # Position so that cur_ink_l - prev_ink_r = gap_w:
            cur_x = prev_ink_r + gap_w + HALF_STROKE - x1

        ink_l = cur_x + x1 - HALF_STROKE
        ink_r = cur_x + x2 + HALF_STROKE
        placed_paths = [_shift_subpath(p, cur_x) for p in paths]
        placed.append((ch, placed_paths, cur_x + x1, cur_x + x2, ink_l, ink_r))

    # White gap measurements
    gaps = []
    for i in range(len(placed) - 1):
        c1 = placed[i][0]
        c2 = placed[i+1][0]
        w_gap = placed[i+1][4] - placed[i][5]
        gaps.append((f"{c1} | {c2}", w_gap))

    # Viewport calculation with symmetric outer margins:
    first_ink_l = placed[0][4]
    last_ink_r = placed[-1][5]

    left_margin = first_ink_l
    vp_width = last_ink_r + left_margin
    vp_width_int = int(round(vp_width))
    dp_width = vp_width * (22.0 / 184.0)
    dp_width_int = int(round(dp_width))

    # Strict assertions to prevent clipping
    assert first_ink_l >= 0.0, f"Left clipping detected: {first_ink_l}"
    assert last_ink_r <= vp_width, f"Right clipping detected: {last_ink_r} > {vp_width}"
    assert CAP_Y - HALF_STROKE >= 0.0, f"Top clipping detected: {CAP_Y - HALF_STROKE}"
    assert BASELINE_Y + HALF_STROKE <= VIEWPORT_HEIGHT, f"Bottom clipping detected: {BASELINE_Y + HALF_STROKE} > {VIEWPORT_HEIGHT}"

    all_subpaths = []
    for item in placed:
        all_subpaths.extend(item[1])

    return " ".join(all_subpaths), vp_width_int, dp_width_int, gaps


# ==============================================================================
# 2. File Template Generators
# ==============================================================================

def generate_android_vector_xml(version: str) -> str:
    """Generates app/src/main/res/drawable/ic_version.xml."""
    path_d, vp_width, dp_width, _ = render_lockup_geometry(version)

    return f"""<?xml version="1.0" encoding="utf-8"?>
<!-- SPDX-FileCopyrightText: 2026 amurcanov -->
<!-- SPDX-License-Identifier: PolyForm-Noncommercial-1.0.0 -->

<!-- Generated by scripts/gen_version_lockup.py. DO NOT EDIT MANUALLY. -->
<vector xmlns:android="http://schemas.android.com/apk/res/android"
    xmlns:aapt="http://schemas.android.com/aapt"
    android:width="{dp_width}dp"
    android:height="22dp"
    android:viewportWidth="{vp_width}"
    android:viewportHeight="184"
    android:autoMirrored="false">

    <path
        android:fillColor="@android:color/transparent"
        android:strokeWidth="13"
        android:strokeAlpha="1"
        android:strokeLineCap="round"
        android:strokeLineJoin="round"
        android:pathData="{path_d}">

        <aapt:attr name="android:strokeColor">
            <gradient
                android:type="linear"
                android:startX="0"
                android:startY="0"
                android:endX="68"
                android:endY="340"
                android:tileMode="clamp">

                <item
                    android:offset="0.0"
                    android:color="#1E88FE" />

                <item
                    android:offset="0.26"
                    android:color="#1576FD" />

                <item
                    android:offset="0.48"
                    android:color="#0B5FFC" />

                <item
                    android:offset="1.0"
                    android:color="#0A5CFC" />

            </gradient>
        </aapt:attr>

    </path>

</vector>
"""


def generate_web_panel_svg_snippet(version: str) -> Tuple[str, int, int, int]:
    """
    Generates exact SVG string and proportional CSS widths for rust-server/web_panel.rs.
    Uses identical 184-grid path and viewBox="0 0 <W> 184".
    """
    clean_ver = version.lstrip("v")
    path_d, vp_width, _, _ = render_lockup_geometry(clean_ver)

    # Proportional CSS widths based on .brand-logo (760 units wide)
    w_desktop = int(round(165.0 * vp_width / 760.0))
    w_tablet = int(round(128.0 * vp_width / 760.0))
    w_mobile = int(round(92.0 * vp_width / 760.0))

    aria_label = f"Версия {clean_ver}"

    svg = (
        f'<svg class="version-logo" viewBox="0 0 {vp_width} 184" role="img" aria-label="{aria_label}" fill="none" stroke="url(#versionLogoGradient)" stroke-width="13" stroke-linecap="round" stroke-linejoin="round">\n'
        f'                    <defs><linearGradient id="versionLogoGradient" gradientUnits="userSpaceOnUse" x1="0" y1="0" x2="68" y2="340"><stop offset="0" stop-color="#1E88FE"></stop><stop offset="0.26" stop-color="#1576FD"></stop><stop offset="0.48" stop-color="#0B5FFC"></stop><stop offset="1" stop-color="#0A5CFC"></stop></linearGradient></defs>\n'
        f'                    <path d="{path_d}"></path>\n'
        f'                </svg>'
    )
    return svg, w_desktop, w_tablet, w_mobile


# ==============================================================================
# 3. File Operations & Sync Verification
# ==============================================================================

def read_version_from_gradle() -> str:
    if not os.path.isfile(GRADLE_FILE):
        raise FileNotFoundError(f"Cannot find {GRADLE_FILE}")
    with open(GRADLE_FILE, "r", encoding="utf-8") as f:
        content = f.read()
    match = re.search(r'versionName\s*=\s*"([^"]+)"', content)
    if not match:
        raise ValueError(f"versionName not found in {GRADLE_FILE}")
    return match.group(1).strip()


def update_web_panel_file(web_panel_path: str, new_svg: str, w_desk: int, w_tab: int, w_mob: int) -> Tuple[bool, str]:
    with open(web_panel_path, "r", encoding="utf-8") as f:
        content = f.read()

    new_content = content

    # 1. Update SVG element
    svg_pattern = re.compile(r'<svg class="version-logo"[^>]*>.*?<\/svg>', re.DOTALL)
    if not svg_pattern.search(new_content):
        raise ValueError(f"Could not locate <svg class=\"version-logo\"...> in {web_panel_path}")
    new_content = svg_pattern.sub(new_svg, new_content, count=1)

    # 2. Update Desktop CSS width
    desk_pattern = re.compile(r'\.version-logo\s*\{\s*display:\s*block;\s*width:\s*\d+px;\s*height:\s*auto;\s*flex:\s*0\s+1\s+auto;\s*\}')
    desk_replacement = f'.version-logo {{ display: block; width: {w_desk}px; height: auto; flex: 0 1 auto; }}'
    if not desk_pattern.search(new_content):
        raise ValueError("Could not locate desktop .version-logo CSS in web_panel.rs")
    new_content = desk_pattern.sub(desk_replacement, new_content, count=1)

    # 3. Update Tablet CSS width (<=768px)
    tab_pattern = re.compile(r'\.version-logo\s*\{\s*width:\s*\d+px;\s*\}')
    tab_replacement = f'.version-logo {{ width: {w_tab}px; }}'
    if not tab_pattern.search(new_content):
        raise ValueError("Could not locate tablet .version-logo CSS in web_panel.rs")
    new_content = tab_pattern.sub(tab_replacement, new_content, count=1)

    # 4. Update Mobile CSS width (<=480px)
    mob_pattern = re.compile(r'\.version-logo\s*\{\s*width:\s*\d+px\s*!important;\s*\}')
    mob_replacement = f'.version-logo {{ width: {w_mob}px !important; }}'
    if not mob_pattern.search(new_content):
        raise ValueError("Could not locate mobile .version-logo CSS in web_panel.rs")
    new_content = mob_pattern.sub(mob_replacement, new_content, count=1)

    changed = (new_content != content)
    return changed, new_content


def main():
    parser = argparse.ArgumentParser(description="CSQTT Canonical Version Lockup Generator")
    parser.add_argument("version", nargs="?", help="Version string (default: read from app/build.gradle.kts)")
    parser.add_argument("--check", action="store_true", help="Check that committed assets match the version")
    args = parser.parse_args()

    version = args.version or read_version_from_gradle()
    clean_ver = version.lstrip("v")

    android_xml = generate_android_vector_xml(clean_ver)
    web_svg, w_desk, w_tab, w_mob = generate_web_panel_svg_snippet(clean_ver)

    if args.check:
        errors = []

        # Check Android XML
        if not os.path.isfile(ANDROID_XML_FILE):
            errors.append(f"Missing Android asset: {ANDROID_XML_FILE}")
        else:
            with open(ANDROID_XML_FILE, "r", encoding="utf-8") as f:
                cur_xml = f.read()
            if cur_xml.strip() != android_xml.strip():
                errors.append(
                    f"{ANDROID_XML_FILE} is out of sync with version {clean_ver}.\n"
                    f"Run `python3 scripts/gen_version_lockup.py` to regenerate."
                )

        # Check Web Panel
        if not os.path.isfile(WEB_PANEL_FILE):
            errors.append(f"Missing Web Panel asset: {WEB_PANEL_FILE}")
        else:
            with open(WEB_PANEL_FILE, "r", encoding="utf-8") as f:
                cur_panel = f.read()
            svg_match = re.search(r'<svg class="version-logo"[^>]*>.*?<\/svg>', cur_panel, re.DOTALL)
            if not svg_match or svg_match.group(0).strip() != web_svg.strip():
                errors.append(
                    f"{WEB_PANEL_FILE} SVG is out of sync with version {clean_ver}.\n"
                    f"Run `python3 scripts/gen_version_lockup.py` to regenerate."
                )

            desk_m = re.search(r'\.version-logo\s*\{\s*display:\s*block;\s*width:\s*(\d+)px;', cur_panel)
            if not desk_m or int(desk_m.group(1)) != w_desk:
                errors.append(f"{WEB_PANEL_FILE} desktop CSS width ({desk_m.group(1) if desk_m else 'None'}px) != expected {w_desk}px.")

            tab_m = re.search(r'\.version-logo\s*\{\s*width:\s*(\d+)px;\s*\}', cur_panel)
            if not tab_m or int(tab_m.group(1)) != w_tab:
                errors.append(f"{WEB_PANEL_FILE} tablet CSS width ({tab_m.group(1) if tab_m else 'None'}px) != expected {w_tab}px.")

            mob_m = re.search(r'\.version-logo\s*\{\s*width:\s*(\d+)px\s*!important;\s*\}', cur_panel)
            if not mob_m or int(mob_m.group(1)) != w_mob:
                errors.append(f"{WEB_PANEL_FILE} mobile CSS width ({mob_m.group(1) if mob_m else 'None'}px) != expected {w_mob}px.")

        if errors:
            print("ERROR: Version lockup check failed:\n" + "\n".join(errors), file=sys.stderr)
            sys.exit(1)
        else:
            print(f"OK: Version lockup assets are up to date for v{clean_ver}.")
            sys.exit(0)

    # Write mode
    print(f"Generating version lockup for v{clean_ver}...")

    # Write Android XML
    with open(ANDROID_XML_FILE, "w", encoding="utf-8") as f:
        f.write(android_xml)
    print(f"  -> Written {ANDROID_XML_FILE}")

    # Write Web Panel
    changed, new_panel_content = update_web_panel_file(WEB_PANEL_FILE, web_svg, w_desk, w_tab, w_mob)
    if changed:
        with open(WEB_PANEL_FILE, "w", encoding="utf-8") as f:
            f.write(new_panel_content)
        print(f"  -> Updated {WEB_PANEL_FILE} (SVG + CSS widths: {w_desk}px, {w_tab}px, {w_mob}px)")
    else:
        print(f"  -> {WEB_PANEL_FILE} already up to date")

    print(f"Successfully generated lockups for version {clean_ver}!")


if __name__ == "__main__":
    main()
