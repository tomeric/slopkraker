# Plan view as SVG (no matplotlib here): parts, generated row rectangles with the street
# side arrowed, annex rings, roads, the 50 m circle and the spawn.
import json, math, sys
SP = sys.argv[1]
win = json.load(open(f"{SP}/data/window.json"))
rec = json.load(open(f"{SP}/spike/recipes.json"))
OX, OY = 185000.0, 330000.0
CX, CZ = 186330 - OX, -(332234 - OY)
HALF = 72.0; SIZE = 1300; S = SIZE / (2 * HALF)
def g(x, y): return (x - OX, -(y - OY))
def px(p): return ((p[0] - CX + HALF) * S, (p[1] - CZ + HALF) * S)
def ring(geo):
    coords = geo["coordinates"]
    if geo["type"] == "MultiPolygon": coords = max(coords, key=lambda p: len(p[0]))
    return [g(x, y) for x, y in coords[0]]
def poly(pts, **kw):
    attrs = " ".join(f'{k.replace("_", "-")}="{v}"' for k, v in kw.items())
    return f'<polygon points="{" ".join(f"{x:.1f},{y:.1f}" for x, y in map(px, pts))}" {attrs}/>'
out = [f'<svg xmlns="http://www.w3.org/2000/svg" width="{SIZE}" height="{SIZE}" viewBox="0 0 {SIZE} {SIZE}" font-family="Helvetica, Arial" style="background:#f4f1ea">',
       f'<rect width="{SIZE}" height="{SIZE}" fill="#f4f1ea"/>']
for r in win["roads"]:
    pts = [px(g(x, y)) for x, y in r["geom"]["coordinates"]]
    out.append(f'<polyline points="{" ".join(f"{x:.1f},{y:.1f}" for x, y in pts)}" fill="none" stroke="#8a8a8a" stroke-width="{r["width"] * S}" stroke-linecap="round" stroke-linejoin="round" opacity="0.6"/>')
    mx, my = pts[len(pts) // 2]
    out.append(f'<text x="{mx:.0f}" y="{my:.0f}" font-size="14" fill="#333" font-style="italic" text-anchor="middle">{r["name"]}</text>')
for p in win["parts"]:
    pts = ring(p["geom"]); tall = (p.get("eaves") or p["h70"]) >= 4.0
    colour = "#b5651d" if tall else ("#e2cfa5" if p["area"] > 15 else "#bdbdbd")
    out.append(poly(pts, fill=colour, stroke="#333", stroke_width=0.8, opacity=0.9))
    cx = sum(x for x, _ in pts) / len(pts); cz = sum(z for _, z in pts) / len(pts); X, Y = px((cx, cz))
    out.append(f'<text x="{X:.0f}" y="{Y:.0f}" font-size="8" fill="#000" text-anchor="middle" dominant-baseline="middle">{p["source_id"][-8:]}</text>')
for o in rec["objects"]:
    yaw = o["yaw"]; ox, oz = o["x"], o["z"]
    ux, uz = math.cos(yaw), math.sin(yaw); vx, vz = -math.sin(yaw), math.cos(yaw)
    w = lambda x, z: (ox + x * ux + z * vx, oz + x * uz + z * vz)
    r = o["recipe"]
    for a in r["annexes"]:
        out.append(poly([w(x, z) for x, z in a["ring"]], fill="none", stroke="#2266cc", stroke_width=1.5, stroke_dasharray="4,3"))
    if r["dwellings"]:
        x0 = r["dwellings"][0]["x0"]; x1 = r["dwellings"][-1]["x1"]; z0, z1 = r["band"]; mid = (x0 + x1) / 2
        out.append(poly([w(x0, z0), w(x1, z0), w(x1, z1), w(x0, z1)], fill="none", stroke="#d00", stroke_width=2))
        for d in r["dwellings"][1:]:
            a, b = px(w(d["x0"], z0)), px(w(d["x0"], z1))
            out.append(f'<line x1="{a[0]:.1f}" y1="{a[1]:.1f}" x2="{b[0]:.1f}" y2="{b[1]:.1f}" stroke="#d00" stroke-width="1.5"/>')
        f0, f1 = px(w(mid, z0)), px(w(mid, z0 - 6))
        out.append(f'<line x1="{f0[0]:.1f}" y1="{f0[1]:.1f}" x2="{f1[0]:.1f}" y2="{f1[1]:.1f}" stroke="#d00" stroke-width="2.5"/>')
        out.append(f'<circle cx="{f1[0]:.1f}" cy="{f1[1]:.1f}" r="4" fill="#d00"/>')
        lx, ly = px(w(mid, z0 - 9))
        out.append(f'<text x="{lx:.0f}" y="{ly:.0f}" font-size="12" fill="#d00" font-weight="bold" text-anchor="middle">{o["name"]}</text>')
    else:
        lx, ly = px(w(0, -1.5))
        out.append(f'<text x="{lx:.0f}" y="{ly:.0f}" font-size="10" fill="#446" text-anchor="middle">{o["name"]}</text>')
c = px((CX, CZ)); out.append(f'<circle cx="{c[0]:.1f}" cy="{c[1]:.1f}" r="{50 * S:.1f}" fill="none" stroke="#090" stroke-width="2" stroke-dasharray="6,6"/>')
sp = rec["spawns"][0]["position"]; s = px((sp[0], sp[2])); out.append(f'<circle cx="{s[0]:.1f}" cy="{s[1]:.1f}" r="9" fill="gold" stroke="#000" stroke-width="2"/><text x="{s[0] + 12:.0f}" y="{s[1] + 5:.0f}" font-size="13">spawn</text>')
out.append(f'<text x="14" y="26" font-size="16" fill="#111">Dassenkuillaan window (50 m, dashed): brown = dwelling parts, cream = annexes, grey = sheds; red = generated rows with party walls, line + dot = street side; blue = annex rings; grey bands = OSM roads. North is up.</text>')
out.append('</svg>')
open(f"{SP}/shots/00-plan.svg", "w").write("\n".join(out)); print("svg written")
