# Notch geometry reference (MacBook lineup) + the "behind-the-notch" reveal

Reference data + the derivation methodology behind `NotchHomeZoneAnchor.notchRect`, captured while
reworking the notch-dock reveal trigger (reveal **only when the cursor crosses *behind* the notch**,
not merely near it). Read this before touching notch geometry or the reveal trigger.

## The one rule: derive at runtime, NEVER hardcode

The notch box (position, width, height) is **read from `NSScreen` at runtime** — never hardcoded per
model. The reason is subtle and load-bearing:

- The **hardware** fixes only the notch's size in **native pixels**.
- macOS reports geometry in **points**, and the point↔pixel ratio is the user's **display-scaling**
  choice (System Settings → Displays → "Larger Text … More Space"). Pick "More Space" and every point
  value below shrinks proportionally — but `NSScreen` still reports the *current* point-space values
  correctly.
- So a per-model point table is a **sanity check only**. The authoritative source is always the live
  `NSScreen` read. `NotchHomeZoneAnchor.notchRect(screenFrame:safeAreaTop:auxLeft:auxRight:)` does this.

### How it's derived (verified correct on real hardware)

```
safeAreaTop = NSScreen.safeAreaInsets.top          // menu-bar / notch height, 0 ⇒ no notch
auxLeft     = NSScreen.auxiliaryTopLeftArea         // usable menu-bar strip LEFT of the notch
auxRight    = NSScreen.auxiliaryTopRightArea        // usable menu-bar strip RIGHT of the notch

notch (Cocoa, bottom-left origin) =
    x:      auxLeft.maxX                             // left edge = right edge of the left strip
    width:  auxRight.minX - auxLeft.maxX             // gap BETWEEN the two strips
    y:      screenFrame.maxY - safeAreaTop           // bottom edge (top edge = physical top)
    height: safeAreaTop
```

Notch present iff `safeAreaTop > 0 && auxLeft && auxRight && auxRight.minX > auxLeft.maxX`. Absence
(notchless built-in **or** any external display) cleanly selects the top-center **tab** path.

## Ground truth — measured on this machine

**MacBook Pro 14" (`Mac17,9`, Apple M5 Pro), default "looks like 1512 × 982" scaling:**

| Property | Points | Pixels @2× |
|---|---|---|
| `screen.frame` | 1512 × 982 | 3024 × 1964 |
| `visibleFrame` | 1512 × 949 (maxY 949) | — |
| `safeAreaInsets.top` | **32** | 64 |
| `auxiliaryTopLeftArea` | (0, 950, 663, 32) | — |
| `auxiliaryTopRightArea` | (848, 950, 664, 32) | — |
| **derived notchRect** | x 663→848, y 950→982 | — |
| notch **width** | **185** | 370 |
| notch **height** | **32** | 64 |
| centered? | midX 755.5 vs screen 756 → **dead-center (±0.5)** | — |

Reproduce anytime with `swift` (no app build needed): instantiate `NSApplication` as `.accessory`,
then read `NSScreen.main` `frame` / `visibleFrame` / `safeAreaInsets` / `auxiliaryTop{Left,Right}Area`.

## Cross-model reference table (sanity check — values are scaling-dependent)

All notched Macs report **`safeAreaInsets.top = 32 pt` at their _default_ scaling** (the notch height ==
the menu-bar height). Native pixels are hardware-fixed; point widths below are at the **default** scale.

| Model | Native px | Default "looks like" (pt) | Scale | notch/menu H | notch W (pt) |
|---|---|---|---|---|---|
| **14" MBP** (2021 M1 Pro/Max → M2 → M3 → **M4** → M5) | 3024 × 1964 | 1512 × 982 | 2.00× | 32 pt | **185** (measured) |
| **16" MBP** (2021 → M2 → M3 → **M4** → M5) | 3456 × 2234 | 1728 × 1117 | 2.00× | 32 pt | ≈185–200 (est.†) |
| **13" MBA** (M2 2022 / M3 2024 / **M4 2025**) | 2560 × 1664 | 1470 × 956 | ≈1.74× | 32 pt | est.† |
| **15" MBA** (M2 2023 / M3 2024 / **M4 2025**) | 2880 × 1864 | 1470 × 956 | ≈1.96× | 32 pt | est.† |

† Estimates — **do not hardcode**. The camera housing is physically ~the same module across the
notched line, so in native pixels the notch width is similar everywhere (~370 px); the point value
follows the model's scale factor. The Airs use a **non-integer default scale**, so their point
geometry is *not* a clean 2× of native — one more reason to only ever trust the runtime read.

Non-notched (always the **tab** path): notchless built-in displays, all external monitors, iMac,
Mac mini / Studio (no built-in display).

**M4 family specifically:** 14"/16" MBP M4 & M4 Pro/Max (late 2024) reuse the 2021 chassis/panel →
identical notch geometry to the M1–M3 14"/16". 13"/15" MBA M4 (early 2025) keep the M2/M3 Air panels.
No M4 introduces new notch dimensions; the runtime derivation covers them all unchanged.

## "Behind the notch" is real, usable cursor space

macOS lets the pointer travel **up into the notch band** — within the notch's x-span the cursor `y`
reaches all the way to `screenFrame.maxY` (the cursor visibly disappears behind the black cutout).
That region is `notchRect` in Cocoa coords, and it's genuinely reachable — which is what makes it a
valid, deliberate hit target rather than a dead zone.

**Consequence for the reveal trigger:** the dock should reveal **only when the cursor enters
`notchRect`** (crosses *behind* the notch), not when it grazes the strip *below* the notch. The notch
sits on the **physical top edge** → an infinite-depth Fitts's-law target you can slam into and stop
dead, and nothing else lives behind the notch (menu items flank it), so a notch-only trigger can
never collide with reaching for a centered menu item. On **notchless / external** displays we mimic
the same feel: trigger on pushing the cursor to the **very top screen edge** at top-center (a thin
band `visibleFrame.maxY → screenFrame.maxY`, tab-width, centered).

Keep-open is unchanged — the contiguous live zone already unions nub ∪ notch ∪ panel, so once shown,
moving *down* onto the rail keeps it open; only the hidden→shown **trigger** moves up into the notch.
