"""Mansion kit: architecture pieces (floor, walls, corner, pillar, staircase, balcony rail, portal arch).

Walls: 4 m long along X, 0.3 m thick (y -0.15..0.15), 5 m high. The room side (with wainscot) faces -Y
(= Godot +Z). Origin at the base centre of the footprint.
"""
import math

from kit import Kit, arch_pts, star_pts

WT = 0.15   # half wall thickness
FACE = -WT  # y of the room-side wall surface


def _wall_extras(m, regions):
    """Wainscot, chair rail, wallpaper stripes, crown moulding on the room side, clipped to solid `regions`
    (list of (x0, x1, z0, z1)). Every element runs the full 4 m so neighbouring walls tile seamlessly."""

    def dec(x0, x1, z0, z1, depth, mat, bevel=0.0, full_x=False, min_h=0.03):
        for (rx0, rx1, rz0, rz1) in regions:
            ix0, ix1, iz0, iz1 = max(x0, rx0), min(x1, rx1), max(z0, rz0), min(z1, rz1)
            if ix1 - ix0 < 0.03 or iz1 - iz0 < min_h:
                continue
            if full_x and (ix1 - ix0) < (x1 - x0) - 1e-6:
                continue
            m.box(ix0, ix1, FACE - depth, FACE + 0.02, iz0, iz1, mat, bevel)

    # wallpaper stripes (period 0.5 m)
    for k in range(8):
        cx = -1.75 + 0.5 * k
        dec(cx - 0.07, cx + 0.07, 1.3, 4.45, 0.02, "WallpaperStripe", full_x=True, min_h=0.5)
    dec(-2, 2, 0.0, 0.25, 0.09, "DarkWood", 0.02)             # skirting
    dec(-2, 2, 0.25, 1.1, 0.05, "DarkWood")                   # wainscot field
    for cx in (-1.5, -0.5, 0.5, 1.5):                         # raised panels
        dec(cx - 0.42, cx + 0.42, 0.38, 0.98, 0.09, "Wood", 0.03, full_x=True, min_h=0.59)
    dec(-2, 2, 1.1, 1.22, 0.11, "Cream", 0.025)               # chair rail
    dec(-2, 2, 4.5, 4.58, 0.03, "Teal")                       # teal ribbon
    dec(-2, 2, 4.62, 4.8, 0.08, "Cream", 0.02)                # crown, lower
    dec(-2, 2, 4.8, 5.0, 0.14, "Cream", 0.03)                 # crown, upper


def wall_4m():
    m = Kit()
    m.box(-2, 2, -WT, WT, 0, 5, "Wallpaper")
    _wall_extras(m, [(-2, 2, 0, 5)])
    return [m.build("wall_4m")]


def wall_door():
    m = Kit()
    ow, oh = 0.7, 2.0
    m.box(-2, -ow, -WT, WT, 0, 5, "Wallpaper")
    m.box(ow, 2, -WT, WT, 0, 5, "Wallpaper")
    m.box(-ow, ow, -WT, WT, oh, 5, "Wallpaper")
    _wall_extras(m, [(-2, -ow, 0, 5), (ow, 2, 0, 5), (-ow, ow, oh, 5)])
    # jambs + header inside the opening
    m.box(-ow, -ow + 0.1, -WT - 0.02, WT + 0.02, 0, oh, "DarkWood", 0.015)
    m.box(ow - 0.1, ow, -WT - 0.02, WT + 0.02, 0, oh, "DarkWood", 0.015)
    m.box(-ow, ow, -WT - 0.02, WT + 0.02, oh - 0.1, oh, "DarkWood", 0.015)
    # door leaf
    m.box(-0.6, 0.6, -0.07, 0.07, 0.0, 1.9, "DarkWood", 0.02)
    for cx in (-0.28, 0.28):
        m.box(cx - 0.22, cx + 0.22, -0.11, -0.05, 0.15, 0.85, "Wood", 0.02)
        m.box(cx - 0.22, cx + 0.22, -0.11, -0.05, 1.0, 1.75, "Wood", 0.02)
    m.sph((0.46, -0.14, 0.95), 0.055, "Gold", 10, 6)
    m.box(0.42, 0.5, -0.115, -0.08, 0.86, 1.04, "Gold", 0.01)
    for z in (0.35, 1.5):
        m.box(-0.62, -0.5, -0.09, -0.06, z, z + 0.12, "Gold")
    # casing, lintel and pediment on the room side
    for s in (-1, 1):
        m.box(s * 0.7, s * 0.86, FACE - 0.07, FACE + 0.02, 0, 2.1, "Cream", 0.02)
    m.box(-0.92, 0.92, FACE - 0.1, FACE + 0.02, 2.02, 2.17, "Cream", 0.025)
    m.poly([(-0.92, 2.17), (0.92, 2.17), (0.0, 2.62)], "xz", FACE - 0.1, FACE + 0.02, "Cream", 0.02)
    m.poly([(-0.6, 2.22), (0.6, 2.22), (0.0, 2.52)], "xz", FACE - 0.13, FACE - 0.08, "Teal")
    m.sph((0.0, FACE - 0.13, 2.3), 0.06, "Gold", 10, 6)
    return [m.build("wall_door")]


def wall_window():
    m = Kit()
    hw, sill, spring = 0.8, 1.5, 3.6
    top = spring + hw
    m.box(-2, -hw, -WT, WT, 0, 5, "Wallpaper")
    m.box(hw, 2, -WT, WT, 0, 5, "Wallpaper")
    m.box(-hw, hw, -WT, WT, 0, sill, "Wallpaper")
    m.poly(arch_pts(0, spring, hw) + [(hw, 5.0), (-hw, 5.0)], "xz", -WT, WT, "Wallpaper")
    _wall_extras(m, [(-2, -hw, 0, 5), (hw, 2, 0, 5), (-hw, hw, 0, sill), (-hw, hw, top, 5)])
    # moonlit panes (recessed) + mullions
    m.poly([(-hw, sill)] + arch_pts(0, spring, hw) + [(hw, sill)], "xz", -0.02, 0.02, "EmitMoon")
    m.box(-0.03, 0.03, -0.07, 0.07, sill, top, "DarkWood")
    for z in (2.3, 3.0, spring):
        m.box(-hw, hw, -0.07, 0.07, z - 0.03, z + 0.03, "DarkWood")
    for a in (50, 130):
        ex, ez = hw * math.cos(math.radians(a)), spring + hw * math.sin(math.radians(a))
        m.beam((0, 0, spring), (ex, 0, ez), 0.06, 0.06, "DarkWood")
    # cream frame (both sides of the wall) and wooden sill
    ro = hw + 0.13
    frame = [(-ro, sill - 0.05)] + arch_pts(0, spring, ro) + [(ro, sill - 0.05), (hw, sill - 0.05), (hw, spring)] \
        + list(reversed(arch_pts(0, spring, hw))) + [(-hw, sill - 0.05)]
    m.poly(frame, "xz", -WT - 0.06, WT + 0.06, "Cream", 0.02)
    m.box(-1.02, 1.02, -0.34, 0.2, sill - 0.12, sill - 0.02, "Wood", 0.03)
    m.box(-0.9, 0.9, -0.25, -0.15, sill - 0.3, sill - 0.12, "Wood", 0.02)
    # curtains + rod
    for s in (-1, 1):
        m.box(s * 0.98, s * 1.42, -0.34, -0.2, 1.2, 4.5, "Red", 0.05)
        m.box(s * 0.95, s * 1.02, -0.36, -0.18, 1.2, 4.5, "Red", 0.03)
        m.sph((s * 1.6, -0.27, 4.55), 0.07, "Gold", 10, 6)
        m.box(s * 0.93, s * 1.45, -0.36, -0.18, 2.35, 2.5, "Gold", 0.02)  # tie-back band
    m.cyl((0, -0.27, 4.55), 0.028, 3.2, "Gold", 8, axis="x")
    return [m.build("wall_window")]


def wall_corner():
    m = Kit()
    m.box(-0.33, 0.33, -0.33, 0.33, 0, 0.3, "DarkWood", 0.03)
    m.box(-0.3, 0.3, -0.3, 0.3, 0.3, 4.6, "Cream", 0.03)
    m.box(-0.34, 0.34, -0.34, 0.34, 1.1, 1.22, "Cream", 0.025)   # chair-rail height ring
    m.box(-0.31, 0.31, -0.31, 0.31, 4.45, 4.55, "Teal")
    m.box(-0.34, 0.34, -0.34, 0.34, 4.55, 4.75, "Cream", 0.03)
    m.box(-0.36, 0.36, -0.36, 0.36, 4.75, 5.0, "Cream", 0.04)
    # dark quoin bands
    for z in (0.85, 2.0, 3.15):
        m.box(-0.315, 0.315, -0.315, 0.315, z, z + 0.08, "Gold", 0.01)
    return [m.build("wall_corner")]


def floor_tile_4x4():
    """Checkerboard parquet, 0.5 m squares. Top surface at z=0 (walkable plane); slab extends to z=-0.15."""
    m = Kit()
    bm = m.bm
    n, s = 8, 0.5
    xs = [-2 + i * s for i in range(n + 1)]
    for i in range(n):
        for j in range(n):
            mat = "Parquet" if (i + j) % 2 == 0 else "ParquetDark"
            v = [bm.verts.new((xs[i], xs[j], 0)), bm.verts.new((xs[i + 1], xs[j], 0)),
                 bm.verts.new((xs[i + 1], xs[j + 1], 0)), bm.verts.new((xs[i], xs[j + 1], 0))]
            f = bm.faces.new(v)
            f.material_index = m._mi(mat)
    d = -0.15
    c = [(-2, -2), (2, -2), (2, 2), (-2, 2)]
    for k in range(4):
        (ax, ay), (bx, by) = c[k], c[(k + 1) % 4]
        f = bm.faces.new([bm.verts.new((ax, ay, 0)), bm.verts.new((bx, by, 0)), bm.verts.new((bx, by, d)), bm.verts.new((ax, ay, d))])
        f.material_index = m._mi("DarkWood")
    f = bm.faces.new([bm.verts.new((x, y, d)) for (x, y) in reversed(c)])
    f.material_index = m._mi("DarkWood")
    import bmesh
    bmesh.ops.recalc_face_normals(bm, faces=bm.faces)
    return [m.build("floor_tile_4x4")]


def pillar():
    m = Kit()
    m.box(-0.5, 0.5, -0.5, 0.5, 0, 0.28, "DarkWood", 0.04)
    m.box(-0.42, 0.42, -0.42, 0.42, 0.28, 0.5, "Cream", 0.03)
    m.torus((0, 0, 0.56), 0.36, 0.06, "Gold", 20, 8)
    m.lathe([(0.34, 0.55, False), (0.33, 0.6), (0.28, 4.4), (0.30, 4.5)], (0, 0, 0), "Cream", seg=12)
    m.torus((0, 0, 4.42), 0.3, 0.05, "Gold", 20, 8)
    m.box(-0.46, 0.46, -0.46, 0.46, 4.5, 4.72, "Cream", 0.03)
    m.box(-0.5, 0.5, -0.5, 0.5, 4.72, 4.95, "Cream", 0.04)
    m.box(-0.52, 0.52, -0.52, 0.52, 4.62, 4.68, "Gold")
    m.box(-0.42, 0.42, -0.42, 0.42, 4.95, 5.0, "Gold")
    return [m.build("pillar")]


def grand_staircase():
    """6 m wide, 6 m deep (y -3..3), 10 steps of 0.2 m rise / 0.45 m run then a 1.5 m landing at z=2.0.
    The bottom of the stairs faces -Y (Godot +Z); the landing meets the wall behind (+Y)."""
    m = Kit()
    N, rise, run, W = 10, 0.2, 0.45, 3.0
    y0 = -3.0
    for k in range(1, N + 1):
        yf = y0 + run * (k - 1)
        z = rise * k
        m.box(-W, W, yf, yf + run, 0, z - 0.03, "Cream")                      # riser block
        m.box(-W, W, yf - 0.04, yf + run, z - 0.03, z, "Wood", 0.01)           # tread with nosing
        m.box(-1.1, 1.1, yf - 0.045, yf + run, z, z + 0.02, "Red")             # carpet runner tread
        m.box(-1.1, 1.1, yf - 0.065, yf - 0.04, z - rise + 0.03, z, "Red")     # carpet on riser
        m.cyl((0, yf - 0.05, z + 0.02), 0.016, 2.36, "Gold", 6, axis="x")      # stair rod
    yl = y0 + run * N
    m.box(-W, W, yl, 3.0, 0, 1.97, "Cream")
    m.box(-W, W, yl, 3.0, 1.97, 2.0, "Wood", 0.01)
    m.box(-1.1, 1.1, yl, 3.0, 2.0, 2.02, "Red")
    # banisters on both sides
    for s in (-1, 1):
        bx = s * 2.86
        ys = [y0 + run * (k - 0.5) for k in range(1, N + 1)]
        for k, y in enumerate(ys, start=1):
            z = rise * k
            m.cyl((bx, y, z + 0.45), 0.032, 0.9 - 0.02, "DarkWood", 6)
        for y in (yl + 0.3, yl + 0.6, yl + 0.9, yl + 1.2):                       # landing balusters
            m.cyl((bx, y, 2.0 + 0.45), 0.032, 0.88, "DarkWood", 6)
        p0 = (bx, ys[0] - 0.19, 1.1 - 0.084)
        p1 = (bx, ys[-1], rise * N + 0.9)
        m.beam(p0, p1, 0.1, 0.08, "Wood", 0.02)
        m.beam((bx, ys[-1], 2.9), (bx, 2.86, 2.9), 0.1, 0.08, "Wood", 0.02)
        # newels
        m.box(bx - 0.11, bx + 0.11, ys[0] - 0.30, ys[0] - 0.08, 0.0, 1.3, "DarkWood", 0.02)
        m.sph((bx, ys[0] - 0.19, 1.4), 0.12, "Gold", 12, 8)
        m.box(bx - 0.11, bx + 0.11, 2.64, 2.86, 2.0, 3.05, "DarkWood", 0.02)
        m.sph((bx, 2.75, 3.15), 0.12, "Gold", 12, 8)
    return [m.build("grand_staircase")]


def balcony_rail_4m():
    """4 m rail section, 1.1 m high; half a post at each end so two sections join into one full post."""
    m = Kit()
    m.box(-2, 2, -0.08, 0.08, 0.1, 0.24, "DarkWood", 0.02)
    m.box(-2, 2, -0.11, 0.11, 0.98, 1.1, "Wood", 0.03)
    m.box(-2, 2, -0.09, 0.09, 1.1, 1.13, "Gold", 0.01)
    for k in range(15):
        x = -1.75 + 0.25 * k
        m.lathe([(0.032, 0.24, True), (0.05, 0.36), (0.032, 0.5), (0.03, 0.85), (0.04, 0.92), (0.032, 0.98)], (x, 0, 0), "Cream", seg=6)
    for s in (-1, 1):
        m.box(s * 1.86, s * 2.0, -0.1, 0.1, 0.0, 1.16, "DarkWood", 0.02)
        m.sph((s * 1.93, 0, 1.2), 0.07, "Gold", 10, 6)
    return [m.build("balcony_rail_4m")]


def _u_ring(r_in, r_out, spring, z0=0.0, n=14):
    """U-shaped polygon (legs + arch) between two concentric arch outlines, in the XZ plane."""
    outer = [(-r_out, z0)] + arch_pts(0, spring, r_out, n) + [(r_out, z0)]
    inner = [(r_in, z0)] + list(reversed(arch_pts(0, spring, r_in, n))) + [(-r_in, z0)]
    return outer + inner


def _u_fill(r, spring, z0=0.0, n=14):
    return [(-r, z0)] + arch_pts(0, spring, r, n) + [(r, z0)]


def minigame_door_arch():
    """Ornate glowing portal: 3.2 m wide, 0.68 deep, 4.2 high; opening 2.0 wide x 3.6 high to the floor."""
    m = Kit()
    sp = 2.6
    m.poly(_u_ring(1.0, 1.6, sp), "xz", -0.3, 0.3, "Cream", 0.02)
    m.poly(_u_ring(1.0, 1.14, sp), "xz", -0.35, 0.35, "Gold", 0.012)             # inner gold band
    m.poly(_u_ring(1.28, 1.4, sp, z0=0.35), "xz", -0.34, 0.34, "Teal")     # teal band
    m.poly(_u_ring(1.5, 1.6, sp), "xz", -0.34, 0.34, "Gold")              # outer gold band
    for s in (-1, 1):                                                           # plinths
        m.box(s * 1.05, s * 1.75, -0.4, 0.4, 0, 0.4, "DarkWood", 0.05)
        m.box(s * 1.1, s * 1.7, -0.42, 0.42, 0.4, 0.5, "Gold", 0.02)
    # keystone star + studs around the arch
    m.poly(star_pts(0, 3.92, 0.34, 0.16), "xz", -0.4, -0.3, "Gold", 0.015)
    for a in range(20, 180, 20):
        if a == 90:
            continue
        rr = 1.34
        x, z = rr * math.cos(math.radians(a)), sp + rr * math.sin(math.radians(a))
        m.sph((x, -0.35, z), 0.075, "EmitPortal", 8, 6)
    for s in (-1, 1):
        for z in (0.95, 1.6, 2.25):
            m.sph((s * 1.34, -0.35, z), 0.075, "EmitPortal", 8, 6)
    # glowing portal: concentric arches, each proud of the one behind
    layers = [(1.0, "EmitPortalDeep"), (0.82, "EmitPortal"), (0.64, "EmitPortalDeep"), (0.46, "EmitPortal"),
              (0.28, "EmitPortalDeep")]
    for i, (r, mat) in enumerate(layers):
        m.poly(_u_fill(r, sp), "xz", -0.02 - 0.035 * i, 0.06, mat)
    return [m.build("minigame_door_arch")]


PIECES = {
    "floor_tile_4x4": floor_tile_4x4,
    "wall_4m": wall_4m,
    "wall_door": wall_door,
    "wall_window": wall_window,
    "wall_corner": wall_corner,
    "pillar": pillar,
    "grand_staircase": grand_staircase,
    "balcony_rail_4m": balcony_rail_4m,
    "minigame_door_arch": minigame_door_arch,
}
