#!/usr/bin/env python3
"""Turns the FES2014a tidal current atlas into the compact file BoatToolsKit reads.

The FES atlas is global, 1/16°, 34 constituents, two directions, NetCDF 4 — tens
of gigabytes that no phone wants and no Swift package should learn to parse. This
script cuts a box out of it and writes the format described in TIDAL_STREAMS.md:
one little-endian file holding, per node and per constituent, the eastward and
northward velocity as an in-phase and a quadrature component.

The conversion to components is done here rather than in the app because an
amplitude and a phase cannot be interpolated between grid nodes — the mean of
355° and 5° is 180° — whereas the components can.

Usage:

    fes-currents-to-atlas.py --inspect eastward_velocity/m2.nc

    fes-currents-to-atlas.py \\
        --eastward  fes2014a_currents/eastward_velocity \\
        --northward fes2014a_currents/northward_velocity \\
        --south 48 --north 52 --west -6 --east 3 \\
        --output channel.btsa

    fes-currents-to-atlas.py --selftest fixture.btsa

The data itself is not redistributable with this script: see TIDAL_STREAMS.md.
"""

from __future__ import annotations

import argparse
import math
import struct
import sys
from pathlib import Path

MAGIC = b"BTSA"
VERSION = 1
HEADER_SIZE = 56
NAME_SIZE = 8
# The unit the velocity components are stored in, in metres per second.
COMPONENT_STEP = 0.001
INT16_LIMIT = 32767

# The names BoatToolsKit knows, in the order it prefers to see them. Msqm is
# deliberately absent: its Doodson coefficients could not be corroborated, so
# the library reports it as unsupported rather than predict with a guess.
KNOWN = [
    "Sa", "Ssa", "Mm", "Msf", "Mf", "Mtm",
    "Q1", "O1", "P1", "S1", "K1", "J1",
    "EPS2", "2N2", "MU2", "N2", "NU2", "M2", "MKS2", "LA2", "L2",
    "T2", "S2", "R2", "K2",
    "M3", "N4", "MN4", "M4", "MS4", "S4", "M6", "M8",
]

LATITUDE_NAMES = ("lat", "latitude", "lats", "y")
LONGITUDE_NAMES = ("lon", "longitude", "lons", "x")


def fail(message: str) -> None:
    print(f"error: {message}", file=sys.stderr)
    raise SystemExit(1)


# ---------------------------------------------------------------- NetCDF side


def open_dataset(path: Path):
    try:
        from netCDF4 import Dataset
    except ImportError:
        fail(
            "reading NetCDF needs the netCDF4 package: "
            "python3 -m pip install netCDF4"
        )
    return Dataset(str(path))


def find_axis(dataset, candidates: tuple[str, ...]) -> str:
    for name in dataset.variables:
        if name.lower() in candidates:
            return name
    fail(f"no axis among {candidates} in the file; run --inspect to see what is there")


def find_pair(dataset) -> tuple[str, str]:
    """The amplitude and phase variables, by name or by their long_name."""
    amplitude = phase = None
    for name, variable in dataset.variables.items():
        if variable.ndim != 2:
            continue
        lowered = name.lower()
        described = str(getattr(variable, "long_name", "")).lower()
        if lowered in ("ua", "va", "amplitude", "amp") or "amplitude" in described:
            amplitude = amplitude or name
        elif lowered in ("ug", "vg", "phase", "phase_lag") or "phase" in described:
            phase = phase or name
    if amplitude is None or phase is None:
        fail("could not tell the amplitude and phase variables apart; run --inspect")
    return amplitude, phase


def to_metres_per_second(units: str) -> float:
    """The factor taking a stated unit to metres per second."""
    cleaned = units.strip().lower().replace(" ", "").replace("**", "")
    if cleaned in ("m/s", "ms-1", "m.s-1", "meter/s", "metres/s"):
        return 1.0
    if cleaned in ("cm/s", "cms-1", "cm.s-1"):
        return 0.01
    if cleaned in ("mm/s", "mms-1"):
        return 0.001
    fail(f"unknown velocity unit {units!r}; add it to to_metres_per_second")


def inspect(path: Path) -> None:
    dataset = open_dataset(path)
    print(f"{path}")
    for name, variable in dataset.variables.items():
        attributes = {
            key: getattr(variable, key)
            for key in ("units", "long_name", "standard_name", "_FillValue")
            if hasattr(variable, key)
        }
        print(f"  {name}  {variable.dtype}  {variable.shape}  {attributes}")


# ----------------------------------------------------------------- the atlas


class Plane:
    """One constituent's components over the output grid, already in m/s."""

    def __init__(self, nodes: int) -> None:
        self.east_in = [0.0] * nodes
        self.east_quadrature = [0.0] * nodes
        self.north_in = [0.0] * nodes
        self.north_quadrature = [0.0] * nodes


def read_constituent(path: Path, rows, columns, wet, scale_known=None):
    """Reads one file and returns (in-phase, quadrature) over the output grid.

    `wet` is cleared wherever this file has no data, so that a node counts as
    water only when every constituent and both directions have a value there.
    """
    dataset = open_dataset(path)
    latitude_name = find_axis(dataset, LATITUDE_NAMES)
    longitude_name = find_axis(dataset, LONGITUDE_NAMES)
    amplitude_name, phase_name = find_pair(dataset)
    amplitude_variable = dataset.variables[amplitude_name]
    factor = to_metres_per_second(getattr(amplitude_variable, "units", "cm/s"))

    amplitude = amplitude_variable[:]
    phase = dataset.variables[phase_name][:]
    # FES puts latitude first; if a file ever came the other way round the
    # axes tell us so.
    dimensions = amplitude_variable.dimensions
    latitude_first = dimensions[0] == dataset.variables[latitude_name].dimensions[0]

    in_phase = [0.0] * (len(rows) * len(columns))
    quadrature = [0.0] * (len(rows) * len(columns))
    for r, row in enumerate(rows):
        for c, column in enumerate(columns):
            index = r * len(columns) + c
            a = amplitude[row, column] if latitude_first else amplitude[column, row]
            g = phase[row, column] if latitude_first else phase[column, row]
            if a is None or g is None or a is amplitude.fill_value or hasattr(a, "mask") and a.mask:
                wet[index] = 0
                continue
            try:
                a = float(a) * factor
                g = math.radians(float(g))
            except (TypeError, ValueError):
                wet[index] = 0
                continue
            if not (math.isfinite(a) and math.isfinite(g)):
                wet[index] = 0
                continue
            in_phase[index] = a * math.cos(g)
            quadrature[index] = a * math.sin(g)
    return in_phase, quadrature


def quantise(value: float) -> int:
    step = int(round(value / COMPONENT_STEP))
    return max(-INT16_LIMIT, min(INT16_LIMIT, step))


def write_atlas(path: Path, grid, names, mask, planes) -> None:
    latitude_minimum, longitude_minimum, latitude_step, longitude_step, rows, columns = grid
    with path.open("wb") as handle:
        handle.write(MAGIC)
        handle.write(struct.pack("<HH", VERSION, 0))
        handle.write(
            struct.pack(
                "<dddd", latitude_minimum, longitude_minimum, latitude_step, longitude_step
            )
        )
        handle.write(struct.pack("<III", rows, columns, len(names)))
        handle.write(struct.pack("<I", 0))
        for name in names:
            encoded = name.encode("ascii")
            if len(encoded) > NAME_SIZE:
                fail(f"constituent name {name!r} does not fit in {NAME_SIZE} bytes")
            handle.write(encoded + b"\0" * (NAME_SIZE - len(encoded)))
        handle.write(bytes(mask))
        for plane in planes:
            for values in (
                plane.east_in,
                plane.east_quadrature,
                plane.north_in,
                plane.north_quadrature,
            ):
                handle.write(struct.pack(f"<{len(values)}h", *(quantise(v) for v in values)))


def convert(arguments) -> None:
    eastward = Path(arguments.eastward)
    northward = Path(arguments.northward)
    wanted = (
        [name.strip() for name in arguments.constituents.split(",") if name.strip()]
        if arguments.constituents
        else None
    )

    available = {}
    for file in sorted(eastward.glob("*.nc")):
        stem = file.stem
        match = next((k for k in KNOWN if k.lower() == stem.lower()), None)
        if match is None:
            print(f"note: skipping {stem}, not a constituent BoatToolsKit predicts with")
            continue
        if wanted and match.lower() not in (w.lower() for w in wanted):
            continue
        partner = northward / file.name
        if not partner.exists():
            fail(f"{file.name} has no northward counterpart in {northward}")
        available[match] = (file, partner)
    if not available:
        fail(f"no usable constituent files found in {eastward}")

    names = [name for name in KNOWN if name in available]
    first = available[names[0]][0]
    dataset = open_dataset(first)
    latitudes = [float(v) for v in dataset.variables[find_axis(dataset, LATITUDE_NAMES)][:]]
    longitudes = [float(v) for v in dataset.variables[find_axis(dataset, LONGITUDE_NAMES)][:]]

    rows = [i for i, lat in enumerate(latitudes) if arguments.south <= lat <= arguments.north]
    if not rows:
        fail("the requested latitude band holds no grid rows")

    def eastings(value: float) -> float:
        return value % 360

    west, east = eastings(arguments.west), eastings(arguments.east)
    if west <= east:
        columns = [i for i, lon in enumerate(longitudes) if west <= eastings(lon) <= east]
    else:
        # The box straddles the prime meridian: take the eastern tail of the
        # source grid, then its western head, so the columns run west to east.
        tail = [i for i, lon in enumerate(longitudes) if eastings(lon) >= west]
        head = [i for i, lon in enumerate(longitudes) if eastings(lon) <= east]
        columns = tail + head
    if not columns:
        fail("the requested longitude band holds no grid columns")

    latitude_step = latitudes[1] - latitudes[0]
    longitude_step = longitudes[1] - longitudes[0]
    grid = (
        latitudes[rows[0]],
        longitudes[columns[0]],
        latitude_step,
        longitude_step,
        len(rows),
        len(columns),
    )
    print(
        f"grid {len(rows)}×{len(columns)} from {grid[0]:.4f}, {grid[1]:.4f} "
        f"by {latitude_step:.5f}, {longitude_step:.5f}"
    )

    mask = [1] * (len(rows) * len(columns))
    planes = []
    for name in names:
        east_file, north_file = available[name]
        plane = Plane(len(rows) * len(columns))
        plane.east_in, plane.east_quadrature = read_constituent(east_file, rows, columns, mask)
        plane.north_in, plane.north_quadrature = read_constituent(
            north_file, rows, columns, mask
        )
        planes.append(plane)
        print(f"  {name}")

    # A node is water only where every file had a value, so clear the
    # components of the nodes that fell out along the way.
    for index, wet in enumerate(mask):
        if not wet:
            for plane in planes:
                plane.east_in[index] = 0.0
                plane.east_quadrature[index] = 0.0
                plane.north_in[index] = 0.0
                plane.north_quadrature[index] = 0.0

    output = Path(arguments.output)
    write_atlas(output, grid, names, mask, planes)
    water = sum(mask)
    print(
        f"wrote {output} — {output.stat().st_size / 1e6:.1f} MB, "
        f"{len(names)} constituents, {water}/{len(mask)} nodes at sea"
    )


# ------------------------------------------------------------------ selftest


def selftest(path: Path) -> None:
    """Writes the fixture the Swift tests read, to prove both ends agree on the
    format. Deliberately dependency-free and deliberately arbitrary: the Swift
    side builds the same bytes from the same rules and compares."""
    rows, columns = 3, 4
    grid = (48.0, -6.0, 0.25, 0.25, rows, columns)
    names = ["M2", "S2", "Msqm"]
    nodes = rows * columns
    mask = [1] * nodes
    mask[0] = 0  # one node ashore, in the south-west corner
    planes = []
    for index in range(len(names)):
        plane = Plane(nodes)
        for node in range(nodes):
            plane.east_in[node] = 0.0 if mask[node] == 0 else (index + 1) * 0.100 + node * 0.001
            plane.east_quadrature[node] = 0.0 if mask[node] == 0 else -(index + 1) * 0.050
            plane.north_in[node] = 0.0 if mask[node] == 0 else node * 0.003
            plane.north_quadrature[node] = 0.0 if mask[node] == 0 else 0.007 - node * 0.001
        planes.append(plane)
    write_atlas(path, grid, names, mask, planes)
    print(f"wrote {path} — {path.stat().st_size} bytes")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--inspect", metavar="FILE", help="print one NetCDF file's variables")
    parser.add_argument("--selftest", metavar="FILE", help="write the Swift tests' fixture")
    parser.add_argument("--eastward", help="directory of eastward velocity files")
    parser.add_argument("--northward", help="directory of northward velocity files")
    parser.add_argument("--south", type=float, help="southern edge, degrees")
    parser.add_argument("--north", type=float, help="northern edge, degrees")
    parser.add_argument("--west", type=float, help="western edge, degrees east")
    parser.add_argument("--east", type=float, help="eastern edge, degrees east")
    parser.add_argument("--constituents", help="comma-separated subset, default every known one")
    parser.add_argument("--output", help="the atlas to write")
    arguments = parser.parse_args()

    if arguments.inspect:
        inspect(Path(arguments.inspect))
        return
    if arguments.selftest:
        selftest(Path(arguments.selftest))
        return
    missing = [
        name
        for name in ("eastward", "northward", "south", "north", "west", "east", "output")
        if getattr(arguments, name) is None
    ]
    if missing:
        fail("missing " + ", ".join("--" + name for name in missing))
    convert(arguments)


if __name__ == "__main__":
    main()
