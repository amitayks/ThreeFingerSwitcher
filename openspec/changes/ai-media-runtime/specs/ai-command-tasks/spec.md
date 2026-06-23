## ADDED Requirements

### Requirement: Media generation is a routed tool executed by a media sink, not a new control flow
The tool registry SHALL additionally aggregate **media-generation** tools (`generate_image` and
`generate_video`) through the **same tool-contributor mechanism** as every other tool, and the existing
route → execute → continue loop SHALL dispatch a routed media call to a **media-generation sink** — a long
asynchronous job that streams step progress and ends in a written file — using the **same** loop, the
**same** per-step write-policy gate (an awaiting-approval step resolved by **DOWN = approve / RIGHT =
skip**), the **same** bounded step cap, and the **same** done/declined/failed result mapping that every
other routed tool uses. Media generation SHALL NOT introduce a separate control path, a separate approval
grammar, or a separate result mapping. A media tool that cannot run (no capable backend; for cloud video no
configured provider or no remaining budget; or media generation disabled) SHALL be **omitted from the route
candidates**, so the router never routes to an unavailable generator. A media step that did not land SHALL
be reported **failed**, and a **cancelled** generation SHALL be a distinct outcome, not a failure.

#### Scenario: A routed media call runs through the existing loop and approval gate
- **WHEN** the model routes a turn to `generate_image` or `generate_video`
- **THEN** the existing loop dispatches it to the media-generation sink, a confirm/dangerous step pauses as
  the same awaiting-approval step (DOWN = approve / RIGHT = skip) before any compute or spend, and its
  result is fed back as a tool turn — with no separate control flow

#### Scenario: An unavailable media tool is not offered to the router
- **WHEN** no runtime can produce the requested media kind, or the cloud-video provider/budget is
  unavailable, or media generation is disabled
- **THEN** the media tool is omitted from the route candidates and the router cannot route to it

#### Scenario: A media side effect that did not land is reported failed, not done
- **WHEN** a routed media generation fails or its asset cannot be written
- **THEN** the step is reported failed with a clean headline, never reported done

#### Scenario: A cancelled media generation is distinct from a failure
- **WHEN** a routed media generation is cancelled (discarded)
- **THEN** the step ends as cancelled, fed back as such, and is not reported as a failure
