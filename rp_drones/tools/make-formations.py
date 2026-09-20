#!/usr/bin/env python3
"""Generate rp_drones/shared/formations.lua.

A drone show is a sequence of SHAPES, and a shape is a list of points. Typing
those points by hand is how you get a ring that is subtly not a circle and a
heart whose two lobes do not match, so they are generated here instead and the
Lua file is an artefact, never a source.

WHAT A SHAPE IS HERE
--------------------
Every shape is defined once, as strokes in a normalised square: `u` to the
right, `v` up, both in [-1, 1], and `w` for depth, which is 0 for every shape
that ships (a drone show draws a picture in a plane facing the audience -- the
depth axis is there so a future shape can use it without a format change).

Points are then spread at EQUAL ARC LENGTH along the strokes, not at equal
parameter, because equal parameter bunches drones where a curve is tight. On a
heart that is the difference between a heart and a heart with two dense knots
at the top. Multi-stroke shapes -- the digits -- divide the drones between
strokes in proportion to stroke length, so a long diagonal gets more drones
than a short bar and the spacing stays even across the whole figure.

EVERY SHAPE IS GENERATED AT THE SAME COUNT, on purpose. The engine refuses a
formation whose point count is not the drone count rather than parking the
leftovers, because a parked drone is a lit box hanging in the sky next to the
picture: there is no cheap way to hide one (`visible` respawns the entity, and
the light host carries geometry whether or not the lamp is lit).

USAGE
-----
    python tools/make-formations.py                  # 48 drones, the default
    python tools/make-formations.py --count 64
    python tools/make-formations.py --count 64 --out shared/formations.lua

Then set `droneCount` in shared/config.lua to the same number. The resource
prints a loud refusal on start if the two disagree.
"""

from __future__ import annotations

import argparse
import math
import os
import sys

DEFAULT_COUNT = 48
# The generated file lives next to config.lua; both are shared scripts.
DEFAULT_OUT = os.path.join("shared", "formations.lua")

Point = tuple[float, float]
Stroke = list[Point]


# ---------------------------------------------------------------------------
# Shapes, as strokes in the normalised square
# ---------------------------------------------------------------------------


def _sample_curve(fn, segments: int) -> Stroke:
    """A closed parametric curve as a dense polyline, t in [0, 1)."""
    return [fn(i / segments) for i in range(segments)]


def ring() -> tuple[list[Stroke], bool]:
    """A circle. The reference shape: if this is not round, nothing else is."""

    def point(t: float) -> Point:
        angle = t * 2.0 * math.pi
        return (math.cos(angle), math.sin(angle))

    return [_sample_curve(point, 720)], True


def heart() -> tuple[list[Stroke], bool]:
    """The classic parametric heart, normalised to fill the square.

    x = 16 sin^3 t, y = 13 cos t - 5 cos 2t - 2 cos 3t - cos 4t. It is the
    curve everyone recognises, and it is worth using the real one: an ad-hoc
    heart built from two arcs and a V has a visible seam where they meet, and
    at sixty metres a seam is the only thing anyone looks at.
    """

    def point(t: float) -> Point:
        angle = t * 2.0 * math.pi
        x = 16.0 * math.sin(angle) ** 3
        y = (
            13.0 * math.cos(angle)
            - 5.0 * math.cos(2.0 * angle)
            - 2.0 * math.cos(3.0 * angle)
            - math.cos(4.0 * angle)
        )
        return (x, y)

    return [_sample_curve(point, 1440)], True


def _seven(origin: float, width: float) -> list[Stroke]:
    """One digit 7, as two strokes: the top bar, then the diagonal.

    Drawn as one continuous path (bar left-to-right, then down the diagonal)
    so the arc-length spread walks the glyph the way a pen would and the
    corner gets exactly one drone rather than two on top of each other.
    """
    left = origin
    right = origin + width
    return [
        [
            (left, 1.0),
            (right, 1.0),
            (left + width * 0.30, -1.0),
        ]
    ]


def seventy_seven() -> tuple[list[Stroke], bool]:
    """77 -- the logo. Two glyphs, a gap between them, centred on u = 0."""
    glyph = 0.80  # glyph width in normalised units
    gap = 0.30
    total = glyph * 2.0 + gap
    left = -total / 2.0
    strokes: list[Stroke] = []
    strokes += _seven(left, glyph)
    strokes += _seven(left + glyph + gap, glyph)
    return strokes, False


# ---------------------------------------------------------------------------
# A stroke font, for writing in the sky
# ---------------------------------------------------------------------------
#
# Not a dot matrix. A 5x7 bitmap glyph lights a fixed number of cells, so the
# drone count is decided by the font and a count that does not match it either
# thins the letters into nothing or piles drones on top of each other. Strokes
# go through the same arc-length walker as every other shape here, so a word
# renders at WHATEVER count you have -- more drones simply means a denser line.
#
# Glyphs live in a 4-wide, 6-tall box with the origin bottom-left, and each is
# a list of polylines. Advance widths differ per glyph because a slash is not
# as wide as an O, and a proportional sign reads better than a monospaced one
# at the distance these are watched from.

GLYPHS: dict[str, tuple[list[Stroke], float]] = {
    # (strokes, advance width)
    "O": ([[(0, 1), (0, 5), (1, 6), (3, 6), (4, 5), (4, 1), (3, 0), (1, 0), (0, 1)]], 4.0),
    "P": ([[(0, 0), (0, 6), (3, 6), (4, 5), (4, 4), (3, 3), (0, 3)]], 4.0),
    # Two strokes: the C-shape and the middle bar. The walker shares the drones
    # between them by length, so the bar never starves.
    # The middle bar is INSET from the stem by a third of a unit. Touching it
    # exactly let the stem's arc-length walk land a point on the bar's start
    # point -- two drones in one place, and a hole elsewhere to pay for it.
    # Invisible at any distance this is watched from; the check in `main`
    # catches the next one.
    "E": ([[(4, 6), (0, 6), (0, 0), (4, 0)], [(0.35, 3), (2.8, 3)]], 4.0),
    "N": ([[(0, 0), (0, 6), (4, 0), (4, 6)]], 4.0),
    "7": ([[(0, 6), (4, 6), (1.2, 0)]], 4.0),
    # The PLAY TEST set. Every crossbar and stem that meets another stroke is
    # INSET from it by a third of a unit, for the same reason as the E: a
    # junction is where the arc-length walk stacks two drones, and the
    # generator refuses the whole formation when it does.
    "A": ([[(0, 0), (2, 6), (4, 0)], [(0.85, 2.4), (3.15, 2.4)]], 4.0),
    "L": ([[(0, 6), (0, 0), (4, 0)]], 4.0),
    "Y": ([[(0, 6), (2, 3), (4, 6)], [(2, 2.65), (2, 0)]], 4.0),
    "T": ([[(0, 6), (4, 6)], [(2, 5.65), (2, 0)]], 4.0),
    # A polyline S: two bowls sharing a spine, drawn as one pen stroke so the
    # walker spaces it as one line.
    "S": ([[(4, 5.3), (3, 6), (1, 6), (0, 5), (0, 3.7), (1, 3), (3, 3),
            (4, 2.3), (4, 1), (3, 0), (1, 0), (0, 0.7)]], 4.0),
    # STEEPER AND TALLER THAN THE CAP HEIGHT, which is how a solidus is told
    # apart from a seven by SHAPE rather than by spacing.
    #
    # The first version leaned the same amount as the 7's diagonal and stopped
    # at the same height, so `//77` came out as four similar diagonal marks at
    # an even pitch -- read from a photograph as a picket fence rather than as
    # two slashes and two sevens. This one rises 7.2 over 0.9 where the seven
    # falls 6 over 2.8: three times the slope, and it overshoots the line top
    # and bottom so the eye has a second cue.
    "/": ([[(0.45, -0.6), (1.35, 6.6)]], 1.8),
    " ": ([], 2.0),
}

GLYPH_GAP = 1.0
LINE_GAP = 2.0

# Extra air between particular pairs, on top of GLYPH_GAP.
#
# Kerning is not decoration here. `//77` is four diagonals in a row, and at the
# stroke density a drone sign runs at, even pitch makes them one object. The
# owner's words were "faut pas que // et 77 sois attache" -- so the pair-to-pair
# gap is the big one, and the within-pair gaps are widened a little so each
# pair still reads as two marks rather than one wide one.
KERNING: dict[tuple[str, str], float] = {
    ("/", "7"): 2.0,
    ("/", "/"): 0.4,
    ("7", "7"): 0.6,
}


def text_strokes(lines: list[str]) -> list[Stroke]:
    """One or more lines of text, as strokes in a common box.

    Lines are centred on each other, so a stacked sign does not come out
    left-aligned and looking like a mistake.
    """
    rendered: list[tuple[float, list[Stroke]]] = []
    for line in lines:
        strokes: list[Stroke] = []
        pen = 0.0
        previous: str | None = None
        for character in line:
            key = character.upper()
            if previous is not None:
                pen += KERNING.get((previous, key), 0.0)
            glyph, advance = GLYPHS.get(key, GLYPHS[" "])
            for stroke in glyph:
                strokes.append([(x + pen, y) for x, y in stroke])
            pen += advance + GLYPH_GAP
            previous = key
        rendered.append((max(0.0, pen - GLYPH_GAP), strokes))

    widest = max((width for width, _ in rendered), default=1.0) or 1.0
    out: list[Stroke] = []
    # First line on top: text reads downward, and the strokes are y-up.
    top = (len(rendered) - 1) * (6.0 + LINE_GAP)
    for index, (width, strokes) in enumerate(rendered):
        dx = (widest - width) / 2.0
        dy = top - index * (6.0 + LINE_GAP)
        for stroke in strokes:
            out.append([(x + dx, y + dy) for x, y in stroke])
    return out


def grid(count: int) -> list[Point]:
    """A filled lattice: the launch pad, and the shape a show starts and ends on.

    NOT a stroke shape, and it does not go through the arc-length spread --
    running a lattice through a path walker treats it as one long zig-zag and
    hands back a diagonal smear, which is exactly what the first version of
    this file did. The points below are final.

    Columns are chosen to be as close to square as the count allows; a count
    that is not a neat rectangle puts the remainder in a short last row,
    centred, which reads as a pad rather than as a mistake.
    """
    columns = max(1, int(round(math.sqrt(count))))
    rows = math.ceil(count / columns)
    points: list[Point] = []
    for index in range(count):
        row = index // columns
        in_row = index - row * columns
        # A short last row is centred rather than left-aligned.
        row_width = min(columns, count - row * columns)
        u = 0.0 if row_width == 1 else (in_row / (row_width - 1)) * 2.0 - 1.0
        v = 0.0 if rows == 1 else 1.0 - (row / (rows - 1)) * 2.0
        points.append((u, v))
    return points


# ---------------------------------------------------------------------------
# Arc-length spreading
# ---------------------------------------------------------------------------


def _stroke_length(stroke: Stroke, closed: bool) -> float:
    total = 0.0
    for index in range(len(stroke) - 1):
        total += math.dist(stroke[index], stroke[index + 1])
    if closed and len(stroke) > 1:
        total += math.dist(stroke[-1], stroke[0])
    return total


def _walk(stroke: Stroke, closed: bool, wanted: int) -> list[Point]:
    """`wanted` points spread at equal arc length along one polyline.

    A stroke that ENDS WHERE IT STARTED is treated as closed whatever the
    caller said, because an open walk puts a point on each end and those two
    ends are the same place -- two drones in one spot, and a hole somewhere
    else in the figure to pay for it. The `O` of OPEN is exactly that shape,
    and it is how the sign first came out with a nearest-neighbour spacing of
    zero.
    """
    if wanted <= 0:
        return []
    if len(stroke) > 2 and math.dist(stroke[0], stroke[-1]) < 1e-9:
        stroke, closed = stroke[:-1], True
    if len(stroke) == 1 or wanted == 1:
        return [stroke[0]]

    path = stroke + [stroke[0]] if closed else stroke
    lengths = [math.dist(path[i], path[i + 1]) for i in range(len(path) - 1)]
    total = sum(lengths)
    if total <= 0.0:
        return [stroke[0]] * wanted

    # A closed curve has no end to land on, so the last point must not repeat
    # the first: it gets `wanted` intervals. An open stroke gets `wanted - 1`,
    # which puts a drone on each end -- the tip of a 7 needs one.
    step = total / (wanted if closed else (wanted - 1))

    out: list[Point] = []
    segment = 0
    walked = 0.0  # distance consumed inside the current segment
    for index in range(wanted):
        target = index * step
        # Advance to the segment containing `target`.
        while segment < len(lengths) - 1 and walked + lengths[segment] < target:
            walked += lengths[segment]
            segment += 1
        span = lengths[segment]
        ratio = 0.0 if span <= 0.0 else min(1.0, max(0.0, (target - walked) / span))
        start, end = path[segment], path[segment + 1]
        out.append(
            (
                start[0] + (end[0] - start[0]) * ratio,
                start[1] + (end[1] - start[1]) * ratio,
            )
        )
    return out


def spread(strokes: list[Stroke], closed: bool, count: int) -> list[Point]:
    """`count` points over every stroke, shared out by stroke length."""
    if len(strokes) == 1:
        return _walk(strokes[0], closed, count)

    lengths = [_stroke_length(stroke, closed) for stroke in strokes]
    total = sum(lengths) or 1.0
    # Every stroke keeps at least two drones, or a short bar vanishes.
    shares = [max(2, int(round(count * length / total))) for length in lengths]
    # Reconcile the rounding against the exact count, taking from (or giving
    # to) the longest stroke, where one drone more or less does not show.
    longest = lengths.index(max(lengths))
    while sum(shares) > count and shares[longest] > 2:
        shares[longest] -= 1
    while sum(shares) < count:
        shares[longest] += 1

    points: list[Point] = []
    for stroke, share in zip(strokes, shares):
        points += _walk(stroke, closed, share)
    return points[:count]


# Below this (normalised units) two drones are one drone. At the 32 m stage the
# sign hangs on, one unit is 16 m, so this is about 20 cm.
MIN_GAP = 0.012


def relax(points: list[Point], min_gap: float = MIN_GAP, passes: int = 8) -> list[Point]:
    """Push any two points closer than `min_gap` apart, a little, repeatedly.

    RUNS AFTER `normalise`, and that order is load-bearing: `min_gap` is in
    normalised units, and a first version ran this in glyph-space units where
    the same number is a thousandth of a stroke -- it nudged by nothing, and
    the guard then correctly refused the very counts it was meant to rescue.
    A point pushed a few thousandths outside [-1, 1] is invisible.

    THE COUNT LOTTERY, and why this exists. Arc-length spreading is exact along
    ONE stroke, but a glyph is several: a crossbar meets a stem, a curve closes
    near where the next letter starts. Whether the walker lands a point on each
    side of a junction or two points on top of it depends on the count -- 88
    drones stacked a PLAY TEST junction and cleared every OPEN 77 one, and 96
    did the reverse. A show shares one count across all its figures, so
    "choose a lucky count" is not available.

    So: after spreading, any pair inside `min_gap` is nudged apart along the
    line between them, half the deficit each, for a few passes. The moves are
    a few centimetres at the sizes these are flown at and invisible from the
    ground, and the letters keep their shape because nothing moves more than
    it has to. The guard in `main` stays as the final check, now with a
    threshold that means something.
    """
    pts = [list(p) for p in points]
    for _ in range(passes):
        moved = False
        for i in range(len(pts)):
            for j in range(i + 1, len(pts)):
                dx = pts[j][0] - pts[i][0]
                dy = pts[j][1] - pts[i][1]
                d = math.hypot(dx, dy)
                if d >= min_gap:
                    continue
                moved = True
                if d < 1e-9:
                    # Exactly coincident: pick a direction, any direction.
                    dx, dy, d = 1.0, 0.0, 1.0
                push = (min_gap - d) / 2.0
                ux, uy = dx / d, dy / d
                pts[i][0] -= ux * push
                pts[i][1] -= uy * push
                pts[j][0] += ux * push
                pts[j][1] += uy * push
        if not moved:
            break
    return [(x, y) for x, y in pts]


def normalise(points: list[Point]) -> list[Point]:
    """Centre on the origin and scale so the widest axis fills [-1, 1].

    Both axes are divided by the SAME number, so a circle stays a circle. A
    per-axis fit would turn the ring into an ellipse the moment its bounding
    box was not square, which for a sampled curve it never quite is.
    """
    us = [p[0] for p in points]
    vs = [p[1] for p in points]
    centre_u = (min(us) + max(us)) / 2.0
    centre_v = (min(vs) + max(vs)) / 2.0
    extent = max(max(us) - min(us), max(vs) - min(vs)) / 2.0
    if extent <= 0.0:
        extent = 1.0
    return [((u - centre_u) / extent, (v - centre_v) / extent) for u, v in points]


# ---------------------------------------------------------------------------
# Emission
# ---------------------------------------------------------------------------


def build(count: int) -> list[tuple[str, str, list[Point]]]:
    """Every shipped formation, as (name, one-line description, points)."""
    ring_strokes, ring_closed = ring()
    heart_strokes, heart_closed = heart()
    digits_strokes, digits_closed = seventy_seven()

    return [
        (
            "grid",
            "The launch pad: a lattice the show rises from and settles back onto.",
            relax(normalise(grid(count))),
        ),
        (
            "ring",
            "A circle. The opening shape, and the one that proves the spacing is even.",
            relax(normalise(spread(ring_strokes, ring_closed, count))),
        ),
        (
            "heart",
            "The parametric heart, walked at equal arc length so the lobes match.",
            relax(normalise(spread(heart_strokes, heart_closed, count))),
        ),
        (
            "seventy_seven",
            "77 -- two glyphs, each a bar and a diagonal drawn as one pen stroke.",
            relax(normalise(spread(digits_strokes, digits_closed, count))),
        ),
        (
            "sign_open77",
            "OPEN//77 on one line -- wide and short; wants a lot of drones.",
            relax(normalise(spread(text_strokes(["OPEN//77"]), False, count))),
        ),
        (
            "sign_open77_stacked",
            "OPEN over //77 -- twice the stroke height for the same width.",
            relax(normalise(spread(text_strokes(["OPEN", "//77"]), False, count))),
        ),
        (
            "sign_playtest_stacked",
            "PLAY over TEST -- the opening card of the playtest show.",
            relax(normalise(spread(text_strokes(["PLAY", "TEST"]), False, count))),
        ),
        (
            "sign_open77_plain",
            "OPEN over 77, no slashes -- the shape PLAY TEST flies into.",
            relax(normalise(spread(text_strokes(["OPEN", "77"]), False, count))),
        ),
    ]


def emit(formations, count: int) -> str:
    lines: list[str] = []
    add = lines.append
    add("-- rp_drones -- formation point sets. GENERATED FILE, DO NOT EDIT.")
    add("--")
    add("-- Regenerate with:  python tools/make-formations.py --count %d" % count)
    add("--")
    add("-- Every point is { u, v, w } in a normalised square: `u` right, `v` up,")
    add("-- `w` depth, all in [-1, 1]. The engine maps that square onto a plane in")
    add("-- the sky, so one point set is reusable at any size, anywhere in the city,")
    add("-- facing any direction. Nothing here is in metres.")
    add("--")
    add("-- Points are spread at EQUAL ARC LENGTH along the shape, not at equal")
    add("-- parameter: equal parameter crowds drones where a curve is tight, which")
    add("-- on the heart puts two dense knots at the top of an otherwise even figure.")
    add("--")
    add("-- Every set holds exactly %d points, because the engine refuses a formation" % count)
    add("-- whose count is not the drone count. There is no cheap way to hide a")
    add("-- leftover drone: `visible` respawns the entity, and a light prop carries")
    add("-- its host's geometry whether the lamp is lit or not, so a parked drone is")
    add("-- a box hanging in the sky beside the picture.")
    add("")
    add("RpDronesFormations = {")
    add("    count = %d," % count)
    add("    shapes = {")
    for name, description, points in formations:
        add("        -- %s" % description)
        add("        %s = {" % name)
        for u, v in points:
            add("            { %.4f, %.4f, 0.0000 }," % (u, v))
        add("        },")
        add("")
    # Drop the trailing blank line inside the table.
    if lines[-1] == "":
        lines.pop()
    add("    },")
    add("}")
    add("")
    return "\n".join(lines)


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(
        description="Generate rp_drones formation point sets."
    )
    parser.add_argument(
        "--count",
        type=int,
        default=DEFAULT_COUNT,
        help="Drones in the show, and therefore points per formation (default %d)."
        % DEFAULT_COUNT,
    )
    parser.add_argument(
        "--out",
        default=DEFAULT_OUT,
        help="Where to write the Lua file, relative to the resource root.",
    )
    args = parser.parse_args(argv)

    if args.count < 8:
        parser.error("a show needs at least 8 drones to read as a shape")
    if args.count > 200:
        parser.error(
            "more than 200 drones is past the client's 256-prop projection cap "
            "once anything else in the world is streamed; see the README"
        )

    formations = build(args.count)
    for name, _, points in formations:
        if len(points) != args.count:
            raise SystemExit(
                "internal error: %s produced %d points, wanted %d"
                % (name, len(points), args.count)
            )
        # Two drones in one place is a drone wasted and a hole somewhere else,
        # and it is invisible in the numbers unless something looks for it.
        # Stroke junctions are where it happens: a glyph's crossbar starting
        # exactly on its stem, a curve closing on its own first point.
        closest = min(
            math.dist(points[i], points[j])
            for i in range(len(points))
            for j in range(i + 1, len(points))
        )
        # Half of MIN_GAP: `relax` should have opened every pair to MIN_GAP,
        # and normalising can only shrink distances by a bounded factor, so
        # anything under half is a pair relax could not separate.
        if closest < MIN_GAP * 0.5:
            raise SystemExit(
                "%s has two points %.4f apart at %d drones after relaxation -- "
                "a stroke junction is stacking them; inset the stroke"
                % (name, closest, args.count)
            )

    root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    destination = args.out
    if not os.path.isabs(destination):
        destination = os.path.join(root, destination)
    os.makedirs(os.path.dirname(destination), exist_ok=True)

    # No BOM, LF line endings: a .lua file with a BOM is refused by the Lua
    # loader and the resource dies without a useful message.
    with open(destination, "w", encoding="utf-8", newline="\n") as handle:
        handle.write(emit(formations, args.count))

    print(
        "wrote %s -- %d formations x %d points"
        % (destination, len(formations), args.count)
    )
    print("set `droneCount = %d` in shared/config.lua to match" % args.count)
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
