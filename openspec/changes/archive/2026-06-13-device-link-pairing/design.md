## Context

The transport is unauthenticated and gated off. Per the verified pairing research: there is no SPAKE2/PAKE in CryptoKit, so the recommended robust pattern is a commit-then-confirm construction — an X25519 ECDH authenticated by the short code via HKDF + HMAC confirmation — which is equivalent in spirit to SPAKE2's key-confirmation and is what defeats an active MITM who lacks the code. The data link then runs TLS 1.3 with a pinned self-signed identity. This change implements and tests the cryptographic trust core; the TLS/Keychain integration is a noted follow-up.

## Goals / Non-Goals

**Goals:** a tested, CA-free, server-free pairing trust core: code, code-authenticated X25519 confirmation (with the MITM-resistance property under test), and a pinned-peer store.

**Non-Goals (this change):** the TLS verify-block / `NWParameters` integration; Secure-Enclave/Keychain identity storage; the UI pairing flow (Hub/iOS). These consume this core and are user-verified OS glue.

## Decisions

**D1 — Commit/confirm over X25519, not a hand-rolled PAKE.** CryptoKit has no SPAKE2; hand-rolling one is dangerous. Instead: ephemeral `Curve25519.KeyAgreement`, ECDH shared secret, then `confirmationKey = HKDF-SHA256(secret: shared, salt: codeBytes, info: "device-link-pairing-v1" ‖ pkLow ‖ pkHigh)`. Binding **both** public keys (sorted for role-independence) **and** the code into the derivation means an active MITM — who substitutes its own keys but doesn't know the code — derives a different key and cannot produce a matching HMAC confirmation. This is the research's verified recommendation. *Alternative:* use the code directly as a PSK — rejected (low entropy directly keying TLS is brute-forceable; the code must only authenticate a strong ECDH secret).

**D2 — Role-independent derivation by sorting the two public keys.** Both sides feed the same `info` (sorted `pkA‖pkB`), so initiator and responder compute the identical confirmation key without negotiating roles. Confirmation labels distinguish direction in the HMAC if needed.

**D3 — One attempt, then abort.** The code is low-entropy (~27 bits); allowing repeated guesses online would let an attacker brute-force it. A failed confirmation aborts the pairing (the user re-initiates with a fresh code). Documented as a requirement.

**D4 — Pin the SPKI hash, store as a Codable file (Mac).** The durable trust is the peer's public-key (SPKI) SHA-256 — a public value, so a plain Codable file under Application Support is acceptable on the Mac (the *private* long-lived identity goes in Keychain/Secure Enclave in the follow-up). The store is injectable for tests. *Alternative:* store full certs — unnecessary; the SPKI hash is sufficient for pinning.

## Risks / Trade-offs

- **Confirmation construction correctness is security-critical.** → It is fully unit-tested, including the MITM-distinct-code property; the construction follows the verified research recommendation rather than novel crypto.
- **The TLS integration that actually uses the pin is not in this change.** → Explicitly scoped as a follow-up; the transport opt-in stays off until then, so no false sense of security ships.

## Migration Plan

Additive: a `DeviceLink/Pairing/` folder + tests. No wiring into the transport yet. Rollback = delete the folder.

## Open Questions

- Confirmation transport (who sends first, timeout) is part of the TLS/flow follow-up, not the pure core here.
- Secure Enclave vs software P-256 for the long-lived identity: follow-up decision (Secure Enclave preferred where available).
