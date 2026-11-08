# Tidal streams

A predicted tidal stream, worked out offline from a harmonic atlas.

This is a **forecast, not a measurement**. It never enters `BoatMetricStore`,
which holds what the boat's own instruments say; it has no rank, it competes
with nothing, and the measured stream the store computes by vector subtraction
(see [METRIC_STORE.md](METRIC_STORE.md)) is a separate statement about the same
water. Two independent accounts of the stream are worth more than either alone:
where they agree you can believe the number, and where they disagree something
is wrong with the log calibration, the heading, or the prediction.

- [Getting the data](#getting-the-data)
- [Converting it](#converting-it)
- [The file format](#the-file-format)
- [Predicting with it](#predicting-with-it)
- [How the prediction works](#how-the-prediction-works)
- [Constituents](#constituents)
- [What it cannot tell you](#what-it-cannot-tell-you)

---

## Getting the data

The atlas itself is **not distributed with this library**. It comes from
[AVISO/CNES](https://www.aviso.altimetry.fr/en/data/products/auxiliary-products/global-tide-fes.html),
whose page states that *"FES2014 Tide heights and currents are delivered for all
purposes (scientific, commercial,...)"* and refers to the Aviso licence
agreement for the terms. The files sit on an authenticated FTP server, so an
account is needed; read the licence at registration rather than trusting this
paragraph, because the wording has changed between releases and it is a legal
question, not a technical one. Attribution is expected.

What to fetch, from the `fes2014a_currents` folder:

| Archive | Holds |
|---|---|
| `eastward_velocity.tar.xz` | 34 constituents, eastward component |
| `northward_velocity.tar.xz` | the same 34, northward |

One NetCDF 4 file per constituent per direction, on a 1/16° global grid with no
extrapolation over the coasts. Two things to know before downloading:

- It is the **FES2014a** solution that carries currents, not FES2014b. FES2022
  currents are *not* distributed openly — they go out on request only.
- Global, 34 constituents, two directions is tens of gigabytes. You want a box,
  not the world, which is what the converter is for.

---

## Converting it

```
Scripts/fes-currents-to-atlas.py
```

Needs `netCDF4` (`python3 -m pip install netCDF4`). Look inside a file first, if
only to see what the variables are actually called:

```
Scripts/fes-currents-to-atlas.py --inspect eastward_velocity/m2.nc
```

Then cut out a box:

```
Scripts/fes-currents-to-atlas.py \
    --eastward  fes2014a_currents/eastward_velocity \
    --northward fes2014a_currents/northward_velocity \
    --south 48 --north 52 --west -6 --east 3 \
    --output channel.btsa
```

The whole Channel at 1/16° is a couple of megabytes; western Europe from 40°N to
62°N is about 45 MB. A box straddling the prime meridian is handled, and
`--constituents M2,S2,N2,K1,O1` cuts the file down further when a handful will
do.

Two things the script does rather than the library:

- **It reads the NetCDF.** No Swift package should learn to parse HDF5 to find
  out what a tide is doing, and the variable names in the source files are not
  documented anywhere we could find — hence `--inspect`, and a converter that
  finds the amplitude and phase variables by name or by their `long_name` and
  says so plainly when it cannot.
- **It turns each amplitude and phase lag into an in-phase and a quadrature
  component.** The atlas has to be interpolated between its nodes, and a phase
  cannot be interpolated: the mean of 355° and 5° is 180°. Written as
  components, the interpolation is an ordinary weighted sum.

A node counts as **water** only where every constituent and both directions had
a value. One missing file leaves a hole, and a hole that quietly reads as zero
is worse than no prediction at all.

---

## The file format

Little-endian throughout. `Scripts/fes-currents-to-atlas.py` writes it,
`TidalStreamAtlas` reads it, and
`Tests/BoatToolsKitTests/Resources/tidal-atlas-fixture.btsa` is a twelve-node
file the script's `--selftest` mode wrote: the Swift tests build the same bytes
from the same rules and compare, which is what keeps the two ends in step.

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | `BTSA` |
| 4 | 2 | format version, `UInt16`, currently 1 |
| 6 | 2 | reserved |
| 8 | 8 | latitude of the southern row, `Float64` degrees |
| 16 | 8 | longitude of the western column, `Float64` degrees east |
| 24 | 8 | latitude step, `Float64` degrees |
| 32 | 8 | longitude step, `Float64` degrees |
| 40 | 4 | rows, `UInt32`, running north |
| 44 | 4 | columns, `UInt32`, running east |
| 48 | 4 | constituent count *n*, `UInt32` |
| 52 | 4 | reserved |
| 56 | 8*n* | constituent names, 8 ASCII bytes each, NUL-padded |
| … | rows×columns | land mask, `UInt8`, 1 = water |
| … | *n* × 4 planes | components, `Int16`, unit 0.001 m/s |

Each constituent's four planes come in order — eastward in phase, eastward in
quadrature, northward in phase, northward in quadrature — row-major from the
south-west corner. A name the library has no constituent for is read past and
reported in `unsupportedConstituents`; a file with no usable name at all is
refused.

Columns that span 360° close the globe, so a longitude off the eastern edge is
taken from the western one.

---

## Predicting with it

```swift
let atlas = try TidalStreamAtlas(contentsOf: url)
if let stream = atlas.stream(latitude: 48.6, longitude: -5.1, at: .now) {
    print(stream.set, stream.drift)   // degrees true, knots
}
```

`set` is the direction the water flows **towards** — the convention for a
current, the opposite of the wind's, and the same one `BoatMetricStore`
publishes a measured stream under. `nil` means off the atlas or ashore.

Covering a whole chart at one instant, work the astronomy out once:

```swift
let astronomy = TidalAstronomy(date: when)
for point in grid {
    let stream = atlas.stream(
        latitude: point.latitude, longitude: point.longitude, astronomy: astronomy)
}
```

A node ashore drops out of the interpolation and the remaining corners take up
its weight, so a prediction stays usable right up to the coast, where the
atlas's own nodes start falling on land. All four corners dry and there is
nothing to interpolate.

From the command line:

```
boattools tide --atlas channel.btsa --info
boattools tide --atlas channel.btsa --lat 48.6 --lon=-5.1 --hours 12
```

---

## How the prediction works

A constituent contributes `f · A · cos(V + u − G)`, where *A* and *G* are the
amplitude and Greenwich phase lag the atlas holds, *V* is the equilibrium
argument at that instant, and *f* and *u* are the nodal corrections. Written in
components, which is how the atlas stores it and how the code sums it:

```
contribution = f · (C · cos θ + S · sin θ)      θ = V + u,  C = A cos G,  S = A sin G
```

so the prediction calls no arctangent at all until the very last step, where the
summed eastward and northward velocities become a set and a drift through
`DerivedNavigation.setAndDrift` — the same function the measured stream goes
through.

**The equilibrium argument.** `TidalConstituent` holds five Doodson
coefficients per constituent: multiples of mean lunar time, the Moon's mean
longitude, the Sun's, the lunar perigee and the solar perigee, plus the
conventional ±90° or 180° offset. The speed is *computed from those same
coefficients* rather than tabulated beside them, so the two cannot drift apart —
and the tests then check the computed speeds against the published table, and
separately check that each argument really advances at the speed claimed.

**The time reference is Greenwich mean noon**, not midnight: the classical
argument is written against the hour angle of the mean Sun, which is zero at
upper transit. Half a day out here leaves every semidiurnal constituent correct
and turns every diurnal one backwards, which is the kind of error that hides for
years. Two tests pin it: mean lunar time must equal `h − s` at noon, and S₂ —
whose argument is twice the mean Sun's hour angle and nothing else — must stand
at 0° at noon, 90° at three and 180° at six.

**The nodal corrections.** The Moon's node comes round in 18.6 years and
modulates the lunar constituents as it goes: 4% in amplitude and 2° in phase for
M₂, more than 20% for O₁, over 30% for K₂. `TidalAstronomy` computes Schureman's
auxiliaries — the inclination of the orbit to the equator and the angles ξ, ν,
ν′ and ν″ — and each constituent names the family whose *f* and *u* it takes. A
compound or overtone names its parents instead: M₄ is M₂ twice over, Msf is
S₂ *minus* M₂ and so takes M₂'s factor with the opposite phase.

ξ and ν come from Napier's analogies, each as an arctangent of `tan(N/2)` from
which the half-node must then be taken back out. Leave that step out and both
angles come back an order of magnitude too large while still looking plausible,
so a test asserts they stay inside ±12.5° and ±13.5° across a whole nodal cycle,
and vanish when the node reaches an equinox.

**Cross-checked against an independent formulation.** Schureman's exact factors
and the truncated series Doodson and Warburg published are two separate accounts
of the same modulation. Over one turn of the node the mean of each computed
factor, and the amplitude of its `cos N` term, are held against the published
series coefficients — 1.000 − 0.037 cos N for M₂, 1.009 + 0.187 cos N for O₁,
1.024 + 0.286 cos N for K₂, and so on — and agree to within 0.003.

Sources: Schureman, *Manual of Harmonic Analysis and Prediction of Tides*
(1958), for the equilibrium arguments and the nodal corrections; Doodson and
Warburg (1941) for the series the tests check against; Meeus, *Astronomical
Algorithms*, for the fundamental longitudes. The instant is read as UT1, for
which UTC serves: a second of time moves the fastest of these angles by four
thousandths of a degree.

---

## Constituents

33 of the atlas's 34, in the order the catalogue holds them:

| Band | Constituents |
|---|---|
| Long period | Sa, Ssa, Mm, Msf, Mf, Mtm |
| Diurnal | Q₁, O₁, P₁, S₁, K₁, J₁ |
| Semidiurnal | ε₂, 2N₂, μ₂, N₂, ν₂, M₂, MKS₂, λ₂, L₂, T₂, S₂, R₂, K₂ |
| Terdiurnal and over | M₃, N₄, MN₄, M₄, MS₄, S₄, M₆, M₈ |

**Msqm is deliberately absent.** Its Doodson coefficients could not be
corroborated against a published speed, and a guessed coefficient is a silently
wrong prediction forever, whereas a missing long-period constituent of a few
millimetres per second is a rounding error. The reader names it in
`unsupportedConstituents` and reads past its planes.

A constituent is found by name whatever an atlas calls it: case is ignored and
`lambda2`, `epsilon2` and the like resolve to the catalogue's spelling.

---

## What it cannot tell you

The limits are the atlas's, not the arithmetic's, and they are worth stating
plainly because a number on a screen looks equally confident either way.

- **1/16° is about four miles.** It gives a fair account of the stream offshore
  and over an open shelf. It resolves no race, no overfall, no eddy behind a
  headland and no narrow channel — which is exactly where a stream matters most,
  and where a printed atlas or the local pilot remains the better authority.
- **It is barotropic and tidal only.** Wind-driven and density-driven set are
  not in it, and on some coasts they rival the tidal part.
- **Error grows where it is least welcome.** Typical shelf accuracy is a few
  tenths of a knot; in a goulet or a tidal gate it can be wrong by a factor.
- **Nothing here predicts tide heights.** The FES elevation files have the same
  shape and the same machinery would serve, but this format holds a two-
  component velocity and the library has no height path.

A prediction also makes the leeway computable without a heel coefficient —
`water track = ground track − stream`, so the leeway is the water track less the
heading — but it earns that by substituting the prediction's own error for the
coefficient's, so it is a second opinion rather than an improvement.
