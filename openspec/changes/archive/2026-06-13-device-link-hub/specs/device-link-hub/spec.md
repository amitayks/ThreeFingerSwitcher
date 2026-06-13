## ADDED Requirements

### Requirement: Device-link service lifecycle
The app SHALL run the device-link receive service when, and only when, the `enableDeviceLink` opt-in is on and the app is enabled, starting it on enable and stopping it on disable or quit. Received `LinkItem`s SHALL be routed through the inbound adapter into the existing clipboard store, so they appear in the Clipboard band and reuse retention and lift-to-paste. The local device identity SHALL be derived from the host name.

#### Scenario: Service starts only when opted in
- **WHEN** the `enableDeviceLink` opt-in turns on while the app is enabled
- **THEN** the service starts advertising and accepting; when the opt-in turns off, the service stops

#### Scenario: Received items enter the clipboard store
- **WHEN** the service surfaces a received `LinkItem`
- **THEN** it is adapted to a `ClipboardEntry` (files written to the inbox) and inserted into the clipboard store, where the Clipboard band shows it tagged with its source device

### Requirement: Hub Devices page
The Hub SHALL present a Devices destination with: the `enableDeviceLink` opt-in toggle; the list of paired devices with a Forget action per device; an outbound trigger to send the most recent clipboard item to connected devices; and honest status copy (local-network only; pairing completed on-device; not yet encrypted until the pairing TLS follow-up).

#### Scenario: Devices page surfaces the opt-in and paired devices
- **WHEN** the user opens the Hub Devices page
- **THEN** it shows the enable toggle and the current paired devices, each with a Forget action

#### Scenario: Forget removes a pairing
- **WHEN** the user forgets a paired device
- **THEN** that device is removed from the paired-device store and no longer listed

### Requirement: Local-network and Bonjour declarations
The app bundle SHALL declare `NSLocalNetworkUsageDescription` and the `NSBonjourServices` entry for the device-link service type, so the OS local-network/Bonjour APIs function and the user sees a clear purpose string on the Local Network prompt.

#### Scenario: Info.plist declares the keys
- **WHEN** the app bundle is built
- **THEN** its Info.plist contains a local-network usage description and the device-link Bonjour service type
