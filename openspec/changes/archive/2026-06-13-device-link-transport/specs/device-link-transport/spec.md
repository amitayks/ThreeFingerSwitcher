## ADDED Requirements

### Requirement: Byte-transport seam
The transport SHALL define an abstract bidirectional byte channel (`LinkByteTransport`) that exposes sending a `Data` buffer, a callback for received `Data`, a callback for close (with an optional error), and an explicit close. The connection logic SHALL depend only on this seam, never directly on `Network.framework`, so it is testable with a mock transport.

#### Scenario: Connection logic is transport-agnostic
- **WHEN** a `LinkConnection` is constructed with any `LinkByteTransport`
- **THEN** it sends and receives without referencing `Network.framework`, so a mock loopback transport drives it in tests

### Requirement: Connection handshake and item exchange
A `LinkConnection` SHALL, on start, send a `hello` carrying the local device identity and protocol version. On receiving the peer's `hello`, it SHALL validate version compatibility and, if compatible, record the peer identity and report the handshake; if the major version is incompatible, it SHALL refuse — reporting an error and closing — without processing item frames. It SHALL send a `LinkItem` by writing the pump's outbound buffers to the transport, and SHALL surface every fully-received `LinkItem` via a callback. A malformed/violating inbound stream SHALL tear the connection down with a typed error.

#### Scenario: Hellos are exchanged and identities learned
- **WHEN** two connections over a loopback transport both start
- **THEN** each learns and reports the other's device identity

#### Scenario: An item sent on one side arrives on the other
- **WHEN** one connection sends a `LinkItem` after the handshake
- **THEN** the other surfaces an equal `LinkItem` via its received-item callback

#### Scenario: Incompatible version is refused
- **WHEN** a peer's `hello` carries an incompatible major protocol version
- **THEN** the connection reports an error and closes, and does not surface any item

#### Scenario: Malformed stream tears down with a typed error
- **WHEN** malformed bytes arrive on the transport
- **THEN** the connection reports a `LinkProtocolError` and closes the transport

### Requirement: Bonjour service discovery and acceptance
The transport SHALL provide a `DeviceLinkService` that advertises an `NWListener` over a dedicated Bonjour service type with peer-to-peer enabled (so it can use peer-to-peer Wi-Fi for high-bandwidth transfer), accepts incoming connections, wraps each accepted `NWConnection` in the byte-transport + a `LinkConnection`, and surfaces received `LinkItem`s through a single callback for the app to consume. It SHALL support an explicit start/stop lifecycle.

#### Scenario: Service advertises and accepts
- **WHEN** the service starts
- **THEN** it advertises the device-link Bonjour service with peer-to-peer enabled and accepts an incoming connection into a managed `LinkConnection`

#### Scenario: Received items are surfaced to the app
- **WHEN** an accepted peer sends an item
- **THEN** the service invokes its received-item callback with the reassembled `LinkItem`

#### Scenario: Stop tears down
- **WHEN** the service is stopped
- **THEN** the listener is cancelled and all managed connections are closed
