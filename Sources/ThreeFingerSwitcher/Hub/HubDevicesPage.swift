import SwiftUI

/// The Hub **Devices** page: the device-link opt-in, the paired-device list (with Forget), and the v1
/// outbound trigger. Honest copy about the link being local-network-only and not yet end-to-end
/// encrypted (that arrives with device pairing's TLS follow-up).
struct DevicesPage: View {
    let context: HubContext
    @ObservedObject private var settings: AppSettings

    init(context: HubContext) {
        self.context = context
        _settings = ObservedObject(wrappedValue: context.settings)
    }

    var body: some View {
        HubPage(HubDestination.devices.title,
                subtitle: "Move clipboard items and files between this Mac and your iPhone over your local network.") {
            HubSection(footnote: "Opens a direct local-network link to your paired iPhone — no servers, nothing leaves your network. Items you receive appear in your Clipboard band (turn on Clipboard history to see them there). Pairing is completed on the devices. Note: the link is not yet end-to-end encrypted — that arrives with device pairing — so keep this off on untrusted networks until then.") {
                ToggleRow(title: "Enable the device link", isOn: $settings.enableDeviceLink)
            }

            if let coordinator = context.pairingCoordinator {
                HubSection("Pair a device",
                           footnote: "Show this code and scan it with your iPhone to pair securely — the secret never leaves the screen, and each device pins the other.") {
                    ShowPairingCodeView(coordinator: coordinator)
                }
            }

            HubSection("Paired devices") {
                let devices = context.pairedDevices()
                if devices.isEmpty {
                    Text("No paired devices yet. Pair your iPhone from the companion app to start moving things between them.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    ForEach(devices) { device in
                        HStack(spacing: 10) {
                            Image(systemName: "iphone").foregroundStyle(.secondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(device.name).font(.system(size: 13, weight: .medium))
                                Text("Paired \(device.pairedAt.formatted(date: .abbreviated, time: .omitted))")
                                    .font(.system(size: 11)).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Forget") { context.onForgetDevice(device.id) }
                                .buttonStyle(.borderless)
                                .foregroundStyle(.red)
                        }
                        .padding(.vertical, 2)
                    }
                }
            }

            HubSection("Send",
                       footnote: "Sends the most recent item from your clipboard history to your connected devices.") {
                Button {
                    context.onSendLatestToDevices()
                } label: {
                    Label("Send latest clipboard item to my devices", systemImage: "paperplane")
                }
                .disabled(!settings.enableDeviceLink)
            }
        }
    }
}

/// Shows the Mac's pairing QR and runs the host exchange while visible (advertises only while shown).
private struct ShowPairingCodeView: View {
    @ObservedObject var coordinator: MacPairingCoordinator
    @State private var showing = false

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if showing {
                if let string = coordinator.qrString, let image = QRImage.image(from: string) {
                    Image(nsImage: image)
                        .interpolation(.none)
                        .resizable()
                        .scaledToFit()
                        .frame(width: 180, height: 180)
                        .background(Color.white)
                        .padding(6)
                } else {
                    ProgressView().frame(width: 180, height: 180)
                }
                status
                Button("Hide code") { coordinator.stop(); showing = false }
                    .buttonStyle(.borderless)
            } else {
                Button {
                    coordinator.showCode()
                    showing = true
                } label: {
                    Label("Show pairing code", systemImage: "qrcode")
                }
            }
        }
    }

    @ViewBuilder private var status: some View {
        switch coordinator.status {
        case let .success(name):
            Label("Paired with \(name)", systemImage: "checkmark.seal.fill").foregroundStyle(.green)
        case .failed:
            Label("Pairing failed — show a fresh code.", systemImage: "xmark.octagon").foregroundStyle(.red)
        case .pairing:
            HStack { ProgressView().controlSize(.small); Text("Pairing…") }
        default:
            Text("Scan this with your iPhone.").font(.system(size: 12)).foregroundStyle(.secondary)
        }
    }
}
