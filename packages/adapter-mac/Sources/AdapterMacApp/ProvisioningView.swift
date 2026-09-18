import AdapterMac
import SwiftUI

/// The provisioning window's contents (#143). Deliberately thin: every
/// decision it renders - validation, normalization, picker state, whether
/// the node can start - comes from plain-Swift types in `AdapterMac`
/// (``ProvisioningInput``, ``PairedHeadsets``, ``ProvisioningStatus``)
/// that are unit-tested. This file is the part that isn't, so it should
/// stay as close to "display the model" as possible.
struct ProvisioningView: View {
    @ObservedObject var model: ProvisioningViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("thrw setup")
                .font(.headline)

            VStack(alignment: .leading, spacing: 4) {
                Text("Account ID")
                TextField("tom-personal", text: $model.accountId)
                    .textFieldStyle(.roundedBorder)
                if let error = model.accountIdError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            VStack(alignment: .leading, spacing: 4) {
                Text("Headset")
                headsetPicker
                if let error = model.headsetError {
                    Text(error).font(.caption).foregroundStyle(.red)
                }
            }

            Divider()

            VStack(alignment: .leading, spacing: 4) {
                // #144. A binding that reads the live system state and
                // routes writes through the controller, rather than a
                // stored @Published the user could desync by changing it
                // in System Settings.
                Toggle("Open at Login", isOn: Binding(
                    get: { model.opensAtLogin },
                    set: { _ in model.toggleOpenAtLogin() }
                ))
                if let note = model.loginItemNote {
                    Text(note).font(.caption).foregroundStyle(.secondary)
                }
            }

            Divider()

            HStack {
                Circle()
                    .fill(model.statusColor)
                    .frame(width: 8, height: 8)
                Text(model.statusText)
                    .font(.caption)
                Spacer()
                Button("Refresh devices") { model.reloadDevices() }
                Button("Save") { model.save() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 420)
        .onAppear { model.reloadDevices() }
    }

    @ViewBuilder
    private var headsetPicker: some View {
        switch model.headsetsState {
        case .bluetoothUnavailable:
            // Distinct from "nothing paired" on purpose - an empty picker
            // with no explanation is the failure mode #117 called out.
            Text("Bluetooth appears to be off. Turn it on, then Refresh devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .noDevicesPaired:
            Text("No paired devices. Pair your headset in System Settings \u{2192} Bluetooth, then Refresh devices.")
                .font(.caption)
                .foregroundStyle(.secondary)
        case .devices(let devices):
            Picker("Headset", selection: $model.selectedHeadsetAddress) {
                Text("Select\u{2026}").tag(String?.none)
                ForEach(devices, id: \.address) { device in
                    Text(PairedHeadsets.label(for: device)).tag(String?.some(device.address))
                }
            }
            .labelsHidden()
        }
    }
}
