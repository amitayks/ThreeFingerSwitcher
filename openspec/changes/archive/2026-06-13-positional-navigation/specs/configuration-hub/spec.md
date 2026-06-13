## ADDED Requirements

### Requirement: Positional navigation tuning with a live trackpad preview

The Hub Launcher page SHALL expose the anchored-positional navigation tunables — the **padding-box size**, the **item / band step**, the **edge-margin band**, the **footprint** sensitivity, the **ease** of the held auto-repeat (initial delay, fastest repeat, acceleration ramp), and the **back-off to stop** — as controls, and SHALL present a **live trackpad preview** that visualizes those values as physical zones around the user's actual fingers.

While the preview is visible and the touch engine is running, it SHALL subscribe to live trackpad frames and draw, in real time: the user's **fingertips**, the anchored **center** (the contact centroid), the **padding box** (the step zone), one **item-step ring** (the step granularity inside the box), and the fixed **edge-margin band** at the trackpad border (where it accelerates) — the box and step ring **scaled to the user's current finger footprint**, so spreading or moving the fingers visibly grows, shrinks, and moves them exactly as the navigation model would anchor them. Adjusting any tunable SHALL update the preview immediately (the same values drive the preview and the live navigation). When no live touch is available (the engine is not running, or no fingers are resting), the preview SHALL remain non-empty — showing the zones at a neutral resting position with a hint to rest fingers on the trackpad — and never error.

The preview SHALL read trackpad data through the existing passive multitouch path (no new permission, no new gesture relocation) and SHALL stop observing when it is no longer visible.

#### Scenario: Live zones track the fingers

- **WHEN** the Launcher page's trackpad preview is visible, the touch engine is running, and the user rests fingers on the trackpad
- **THEN** the preview draws the fingertips with the center, the padding box, the item-step ring, and the edge-margin band — positioned at the contact centroid and sized to the current footprint, updating as the fingers move or spread

#### Scenario: Tunables drive the preview live

- **WHEN** the user changes the padding size, the edge margin, or the footprint sensitivity
- **THEN** the preview's corresponding zone resizes immediately, so the slider value is seen as a physical zone

#### Scenario: Graceful when no touch is available

- **WHEN** no live trackpad frames are arriving (the engine is off, or no fingers are down)
- **THEN** the preview shows the zones at a neutral resting position with a "rest your fingers" hint, and does not error or appear blank

#### Scenario: Observation is scoped to visibility and needs no new permission

- **WHEN** the user navigates away from the Launcher page (the preview disappears)
- **THEN** the preview stops observing trackpad frames, and at no point did showing it require a new permission or relocate any gesture
