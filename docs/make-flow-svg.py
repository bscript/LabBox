#!/usr/bin/env python3
"""Writes docs/labbox-flow.svg: the animated "how it works" picture in the README.

Plain SVG with CSS animation, no scripts, so GitHub shows it as an image.
Edit the timeline below and rerun:  python3 docs/make-flow-svg.py
"""
from pathlib import Path

LOOP = 14  # seconds for one full cycle
W, H = 960, 400

css_rules: list[str] = []
keyframes: list[str] = []
_n = 0


def window(start: float, end: float, fade: float = 1.0) -> str:
    """A class that is visible from start% to end% of the loop."""
    global _n
    _n += 1
    name = f"w{_n}"
    a0, a1 = max(start - fade, 0), start
    b0, b1 = end, min(end + fade, 100)
    keyframes.append(
        f"@keyframes {name}{{0%,{a0}%{{opacity:0}}{a1}%,{b0}%{{opacity:1}}{b1}%,100%{{opacity:0}}}}"
    )
    css_rules.append(f".{name}{{opacity:0;animation:{name} {LOOP}s linear infinite}}")
    return name


def travel(points: list[tuple[float, float, float]]) -> str:
    """A class that moves an element through (percent, x, y) points, visible
    only while moving."""
    global _n
    _n += 1
    name = f"m{_n}"
    first, last = points[0], points[-1]
    frames = [f"0%,{first[0] - 0.01}%{{opacity:0;transform:translate({first[1]}px,{first[2]}px)}}"]
    for p, x, y in points:
        frames.append(f"{p}%{{opacity:1;transform:translate({x}px,{y}px)}}")
    frames.append(f"{last[0] + 1}%,100%{{opacity:0;transform:translate({last[1]}px,{last[2]}px)}}")
    keyframes.append(f"@keyframes {name}{{{''.join(frames)}}}")
    css_rules.append(f".{name}{{opacity:0;animation:{name} {LOOP}s ease-in-out infinite}}")
    return name


def text(x, y, s, cls="t", anchor="start", extra=""):
    s = s.replace("&", "&amp;").replace("<", "&lt;").replace(">", "&gt;")
    return f'<text x="{x}" y="{y}" class="{cls} {extra}" text-anchor="{anchor}">{s}</text>'


def packet(label, cls, w=150):
    return (f'<rect x="{-w / 2}" y="-12" width="{w}" height="24" rx="12" class="pk {cls}"/>'
            + text(0, 4, label, "pkt", "middle"))


parts: list[str] = []
add = parts.append

# ---- layout
CL = (40, 140, 230, 170)    # Claude card x, y, w, h
LB = (345, 140, 190, 170)   # LabBox card
VM = (598, 108, 332, 236)   # VM box
cy = 225                    # main line

add(f'<rect x="1" y="1" width="{W - 2}" height="{H - 2}" rx="16" class="bg"/>')

# Internet
add(f'<line x1="440" y1="58" x2="440" y2="{LB[1]}" class="wire dash"/>')
add('<rect x="380" y="20" width="120" height="38" rx="19" class="net"/>')
add(text(440, 44, "Internet", "t b", "middle"))

# Your Mac
add(f'<rect x="20" y="86" width="{W - 40}" height="{H - 106}" rx="14" class="mac"/>')
add(text(36, 110, "YOUR MAC", "cap"))

# wires
add(f'<line x1="{CL[0] + CL[2]}" y1="{cy}" x2="{LB[0]}" y2="{cy}" class="wire"/>')
add(f'<line x1="{LB[0] + LB[2]}" y1="{cy}" x2="{VM[0]}" y2="{cy}" class="wire"/>')

# Claude card
x, y, w, h = CL
add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" class="card"/>')
add(text(x + 16, y + 30, "Claude Code", "t b big"))
add(text(x + 16, y + 50, "decides what to try", "t m"))
add(text(x + 16, y + 92, "“Try this package in", "t i", extra=window(0, 82)))
add(text(x + 16, y + 112, "LabBox first.”", "t i", extra=window(0, 82)))
w_final = window(86, 99) + " still"
add(text(x + 16, y + 86, "“Don’t install it.", "t i bad", extra=w_final))
add(text(x + 16, y + 106, "It read your keys and", "t i bad", extra=w_final))
add(text(x + 16, y + 126, "tried to upload them.”", "t i bad", extra=w_final))
add(text(x + 16, y + h + 26, "your real ~/.ssh and ~/.aws", "t m s"))
add(text(x + 16, y + h + 42, "never enter the VM", "t m s"))

# LabBox card
x, y, w, h = LB
add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" class="card lb"/>')
add(text(x + w / 2, y + 30, "LabBox", "t b big", "middle"))
add(text(x + w / 2, y + 50, "gate · log · report", "t m", "middle"))
status = [
    (0, 13, "waiting", "m"),
    (14, 21, "booting VM · 0.3 s", "acc"),
    (22, 33, "planting fake keys", "acc"),
    (34, 50, "✓ registry.npmjs.org", "ok"),
    (52, 69, "✗ upload BLOCKED", "bad"),
    (70, 99, "report: 8 flags", "bad"),
]
for a, b, s, c in status:
    keep = " still" if s.startswith("report") else ""
    add(text(x + w / 2, y + 137, s, f"t b {c}", "middle", window(a, b) + keep))
add(text(x + w / 2, y + 157, "on your Mac, outside the VM", "t m s", "middle"))

# VM box
x, y, w, h = VM
add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" class="vm still {window(13, 84, 2)}"/>')
add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" class="vmidle"/>')
add(text(x + 16, y + 26, "Linux VM", "t b big"))
add(text(x + 16, y + 44, "own kernel · no network card · no shared folders", "t m s"))
add(text(x + 16, y + 74, "$ npm install quickpdf-render-demo", "code", extra=window(16, 84) + " still"))
w_decoy = window(22, 84) + " still"
add(text(x + 16, y + 100, "fake keys, new every run:", "t m s", extra=w_decoy))
dx = 0
for label in ["~/.ssh/id_rsa", "~/.aws/credentials", "~/.npmrc"]:
    cw = 10 + 6.6 * len(label)
    add(f'<g class="{w_decoy}"><rect x="{x + 16 + dx}" y="{y + 108}" width="{cw}" height="22" rx="6" class="chip"/>'
        + text(x + 16 + dx + cw / 2, y + 123, label, "code s", "middle") + "</g>")
    add(f'<rect x="{x + 16 + dx}" y="{y + 108}" width="{cw}" height="22" rx="6" class="chiphot still {window(46, 84)}"/>')
    dx += cw + 8
add(text(x + 16, y + 156, "> node setup.js", "code", extra=window(30, 84) + " still"))
add(text(x + 16, y + 178, "reads the keys, tries to upload them", "code bad", extra=window(46, 84) + " still"))
w_gone = window(86, 99)
add(f'<rect x="{x}" y="{y}" width="{w}" height="{h}" rx="12" class="gone {w_gone}"/>')
add(text(x + w / 2, y + h / 2 - 4, "VM destroyed", "t b big", "middle", w_gone))
add(text(x + w / 2, y + h / 2 + 18, "nothing kept, nothing on your Mac", "t m", "middle", w_gone))

# caption
add(text(W / 2, H - 30, "Claude decides what to run  ·  LabBox runs it in a throwaway VM  ·  only text comes back",
         "t m", "middle"))

# ---- packets (drawn last so they pass over cards)
lx = LB[0] + LB[2] / 2
p1 = travel([(4, 270, cy - 22), (9, lx, cy - 22), (11, lx, cy - 22), (16, VM[0] + 70, cy - 22)])
add(f'<g class="{p1}">{packet("command", "pcmd")}</g>')

p2 = travel([(34, VM[0] + 40, cy - 22), (38, lx, cy - 22), (44, lx, 70)])
add(f'<g class="{p2}">{packet("GET registry.npmjs.org", "pok", 180)}</g>')

p3 = travel([(52, VM[0] + 40, cy + 22), (57, LB[0] + LB[2] + 60, cy + 22), (61, LB[0] + LB[2] + 60, cy + 22)])
add(f'<g class="{p3}">{packet("POST your keys", "pbad")}</g>')
xw = window(57, 64, 0.5)
add(f'<g class="{xw}"><circle cx="{LB[0] + LB[2] - 2}" cy="{cy + 22}" r="13" class="xdot"/>'
    + text(LB[0] + LB[2] - 2, cy + 27, "✗", "t b xmark", "middle") + "</g>")

p4 = travel([(70, VM[0] + 60, cy + 22), (84, 200, cy + 22)])
add(f'<g class="{p4}">{packet("report: 8 flags", "prep")}</g>')

# ---- styles
palette = """
:root{--bg:#ffffff;--panel:#f6f8fa;--line:#d0d7de;--fg:#1f2328;--mut:#59636e;
--acc:#0969da;--ok:#1a7f37;--bad:#cf222e;--vm:#8250df;--vmbg:#fbf8ff;--hot:#ffebe9}
@media (prefers-color-scheme:dark){:root{--bg:#0d1117;--panel:#161b22;--line:#30363d;--fg:#e6edf3;
--mut:#9198a1;--acc:#4493f8;--ok:#3fb950;--bad:#f85149;--vm:#ab7df8;--vmbg:#1a1527;--hot:#4a1d1f}}
"""
base = """
text{font-family:-apple-system,BlinkMacSystemFont,"Segoe UI",Helvetica,Arial,sans-serif;font-size:13px}
.t{fill:var(--fg)} .m{fill:var(--mut)} .b{font-weight:600} .big{font-size:16px} .s{font-size:11.5px}
.i{font-style:italic} .acc{fill:var(--acc)} .ok{fill:var(--ok)} .bad{fill:var(--bad)}
.code{font-family:ui-monospace,SFMono-Regular,Menlo,Consolas,monospace;font-size:12.5px;fill:var(--fg)}
.code.s{font-size:11px} .cap{font-size:11px;letter-spacing:.08em;fill:var(--mut);font-weight:600}
.bg{fill:var(--bg);stroke:var(--line)} .mac{fill:none;stroke:var(--line);stroke-dasharray:6 5}
.card{fill:var(--panel);stroke:var(--line)} .lb{stroke:var(--acc);stroke-width:1.5}
.vmidle{fill:none;stroke:var(--vm);stroke-width:1.5;stroke-dasharray:4 4}
.vm{fill:var(--vmbg);stroke:var(--vm);stroke-width:2}
.net{fill:var(--panel);stroke:var(--line)}
.wire{stroke:var(--line);stroke-width:2} .dash{stroke-dasharray:5 5}
.chip{fill:var(--panel);stroke:var(--line)} .chiphot{fill:none;stroke:var(--bad);stroke-width:2}
.gone{fill:var(--bg);fill-opacity:.94}
.pk{stroke-width:1.5} .pkt{font-size:11.5px;font-weight:600;fill:#fff}
.pcmd{fill:var(--acc);stroke:var(--acc)} .pok{fill:var(--ok);stroke:var(--ok)}
.pbad{fill:var(--bad);stroke:var(--bad)} .prep{fill:var(--vm);stroke:var(--vm)}
.xdot{fill:var(--bad)} .xmark{fill:#fff;font-size:15px}
"""
# With reduced motion, hold one frame that tells the whole story.
still = """
@media (prefers-reduced-motion:reduce){*{animation:none!important}.still{opacity:1!important}}
"""

svg = f"""<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {W} {H}" width="{W}" height="{H}" role="img" aria-labelledby="title desc">
<title id="title">How LabBox works</title>
<desc id="desc">Claude Code on your Mac asks LabBox to try a package. LabBox boots a throwaway Linux VM with no network card and no shared folders, plants fake keys, and runs the install. The download from the npm registry is allowed. The package reads the fake keys and tries to upload them; LabBox blocks the upload. A report with 8 flags goes back to Claude, the VM is destroyed, and Claude advises not to install.</desc>
<style>{palette}{base}{''.join(css_rules)}{''.join(keyframes)}{still}</style>
{chr(10).join(parts)}
</svg>
"""
out = Path(__file__).with_name("labbox-flow.svg")
out.write_text(svg)
print(f"wrote {out} ({len(svg):,} bytes)")
