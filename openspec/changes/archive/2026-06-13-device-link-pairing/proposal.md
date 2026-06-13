## Why

The transport ships dark because it is unauthenticated. To make it safe on a shared Wi-Fi network we need to bootstrap durable mutual trust between the user's two devices **without a server or CA**: a one-time pairing where a high-entropy code shown on the Mac is entered on the iPhone, an authenticated key agreement proves both sides know the code (defeating an active man-in-the-middle who does not), and each device pins the other's long-lived public-key identity so the code is never needed again. The cryptographic core of this — code generation, the X25519 + code-authenticated confirmation, and the pinned-peer model/store — is pure `CryptoKit` and **fully unit-testable** (including the MITM-resistance property). The actual TLS-on-the-wire integration and Secure-Enclave/Keychain identity storage are OS glue and are a separate follow-up; this change delivers and proves the trust core, keeping the transport gated until pinning is wired.

## What Changes

- **`PairingCode`** — generate a high-entropy numeric code (default 8 digits, ~27 bits) from a cryptographically-secure RNG, with formatting/validation. The code is a low-entropy secret: it is **never sent on the wire** and **never used directly as a key**.
- **`PairingHandshake`** (CryptoKit) — each side holds an ephemeral `Curve25519.KeyAgreement` keypair. Given the peer's public key and the shared code, both derive the **same** confirmation key via `HKDF-SHA256` over the ECDH shared secret, salted by the code and bound to **both** public keys (sorted, so it is role-independent). Each side then exchanges an HMAC confirmation; a matching confirmation proves both knew the code. **A different code yields a different confirmation key, so an active MITM cannot forge a match** — this is the property that secures pairing on an open network. A single wrong attempt aborts (online-guess resistance).
- **`PairedDevice` + `PairedDeviceStore`** — the durable trust record: the peer's identity + a pinned public-key (SPKI) hash + paired-at, persisted so future sessions authenticate by pin without the code. The store is injectable (tested against a temp dir); add / remove / list / `isPinned(spkiHash:)`.
- **Explicitly a follow-up (not this change):** wiring the pinned SPKI into a TLS 1.3 verify block on the transport's `NWParameters`, and storing the local long-lived identity in the Keychain / Secure Enclave. Those are OS-integration glue, user-verified on-device; this change delivers the testable trust core they will consume. The transport opt-in stays off until that wiring lands.

## Capabilities

### New Capabilities
- `device-link-pairing`: serverless, CA-free pairing — a high-entropy code, an X25519 + code-authenticated confirmation that establishes a shared secret and resists an active MITM, and a pinned-peer trust store that makes subsequent sessions code-free. The TLS-wire integration + Keychain identity are a noted follow-up consuming this core.

## Impact

- **New:** `Sources/ThreeFingerSwitcher/DeviceLink/Pairing/PairingCode.swift`, `PairingHandshake.swift`, `PairedDevice.swift`, `PairedDeviceStore.swift`; `Tests/ThreeFingerSwitcherTests/PairingHandshakeTests.swift` (+ store/code tests).
- **Modified:** none yet (the TLS/Keychain wiring is the follow-up).
- **Dependencies:** `CryptoKit` (system framework; available under `swift build`/`swift test`).
- **Permissions / distribution:** none added here (Keychain access-group entitlement comes with the follow-up + the iOS app). App stays unsandboxed.
- **Build:** the trust core is fully `swift test`-verified, including the MITM-resistance test.
- **Privacy/speed/UX:** privacy — the heart of it; no secret ever leaves the device, trust is pinned locally, no server; UX — the code entry flow is surfaced by the Hub/iOS changes.
