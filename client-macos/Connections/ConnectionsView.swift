import SwiftUI

/// The main window: the saved connections on the left, the selected one on the right
struct ConnectionsView: View {
    static let sidebarWidth: CGFloat = 240

    @Bindable var model: ConnectionsModel

    var body: some View {
        HStack(spacing: 0) {
            sidebar
                .frame(width: Self.sidebarWidth)
            Divider()
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var sidebar: some View {
        VStack(spacing: 0) {
            List(selection: $model.selection) {
                ForEach(model.store.profiles) { profile in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(profile.title.isEmpty ? Localization.text(.connectionsUntitled) : profile.title)
                        if !profile.name.isEmpty && !profile.address.isEmpty {
                            Text(profile.address)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                    .tag(profile.id)
                }
            }
            // Double-click or Return on a row connects, as in the Finder a double-click opens
            .contextMenu(forSelectionType: UUID.self) { _ in
            } primaryAction: { ids in
                if let id = ids.first {
                    model.selection = id
                    model.connect()
                }
            }
            Divider()
            HStack(spacing: 4) {
                Button {
                    model.addProfile()
                } label: {
                    Image(systemName: "plus")
                        .accessibilityLabel(Localization.text(.connectionsAdd))
                }
                Button {
                    model.deleteSelected()
                } label: {
                    Image(systemName: "minus")
                        .accessibilityLabel(Localization.text(.connectionsRemove))
                }
                .disabled(model.selection == nil)
                Spacer()
            }
            .buttonStyle(.borderless)
            .padding(8)
        }
        .disabled(model.isBusy)
    }

    @ViewBuilder
    private var detail: some View {
        if model.selectedProfile != nil {
            VStack(spacing: 0) {
                ProfileEditor(model: model)
                    .disabled(model.isBusy)
                Divider()
                HStack(alignment: .firstTextBaseline) {
                    Text(model.status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    if model.isBusy {
                        Button(Localization.text(.connectionActionDisconnect)) {
                            model.disconnect()
                        }
                    } else {
                        Button(Localization.text(.connectionActionConnect)) {
                            model.connect()
                        }
                        .keyboardShortcut(.defaultAction)
                        .disabled(!model.canConnect)
                    }
                }
                .padding()
            }
        } else {
            ContentUnavailableView {
                Label(Localization.text(.connectionsEmptyTitle), systemImage: "display")
            } description: {
                Text(Localization.text(.connectionsEmptyMessage))
            } actions: {
                Button(Localization.text(.connectionsAdd)) {
                    model.addProfile()
                }
                if model.windowsAppInstalled {
                    Button(Localization.text(.connectionsWindowsAppOffer)) {
                        model.importWindowsApp()
                    }
                }
            }
        }
    }
}

/// The fields of the selected profile; each change is saved as it is made
private struct ProfileEditor: View {
    @Bindable var model: ConnectionsModel

    var body: some View {
        Form {
            Section {
                TextField(
                    Localization.text(.profileNameLabel), text: field(\.name),
                    prompt: Text(Localization.text(.profileNamePlaceholder)))
                TextField(
                    Localization.text(.connectionHostLabel), text: field(\.address),
                    prompt: Text(Localization.text(.connectionHostPlaceholder)))
                TextField(
                    Localization.text(.connectionUserLabel), text: field(\.username),
                    prompt: Text(Localization.text(.connectionUserPlaceholder)))
            }
            Section {
                SecureField(
                    Localization.text(.connectionPasswordLabel), text: $model.password,
                    prompt: Text(
                        Localization.text(
                            model.hasSavedPassword ? .profilePasswordSavedPlaceholder : .profilePasswordAskPlaceholder
                        )))
                Toggle(
                    Localization.text(.profilePasswordRemember),
                    isOn: Binding(
                        get: { model.selectedProfile?.remembersPassword ?? false },
                        set: { model.setRemembersPassword($0) }))
                if model.hasSavedPassword || model.hasSavedGatewayPassword {
                    Button(Localization.text(.profilePasswordForget)) {
                        model.forgetPassword()
                    }
                }
            }
            Section(Localization.text(.profileGatewaySection)) {
                TextField(
                    Localization.text(.profileGatewayAddressLabel), text: field(\.gatewayAddress),
                    prompt: Text(Localization.text(.profileGatewayAddressPlaceholder)))
                if !(model.selectedProfile?.gatewayAddress.isEmpty ?? true) {
                    Toggle(
                        Localization.text(.profileGatewaySameCredentials), isOn: flag(\.gatewayUsesServerCredentials))
                    if !(model.selectedProfile?.gatewayUsesServerCredentials ?? true) {
                        TextField(
                            Localization.text(.profileGatewayUserLabel), text: field(\.gatewayUsername),
                            prompt: Text(Localization.text(.connectionUserPlaceholder)))
                    }
                    Toggle(Localization.text(.profileGatewayBypassLocal), isOn: flag(\.gatewayBypassLocal))
                }
            }
            Section(Localization.text(.profileKeyboardSection)) {
                Picker(
                    Localization.text(.profileKeyboardLabel),
                    selection: Binding(
                        get: { model.selectedProfile?.keyboard ?? .settings },
                        set: { keyboard in model.update { $0.keyboard = keyboard } })
                ) {
                    ForEach(ProfileKeyboard.allCases) { keyboard in
                        Text(Localization.text(Self.title(of: keyboard))).tag(keyboard)
                    }
                }
            }
            displaySection
        }
        .formStyle(.grouped)
    }

    /// The desktop of the connection: by the window, in full screen, or of a fixed size chosen from the list or typed
    private var displaySection: some View {
        let mode = model.selectedProfile?.displayMode ?? .window
        let fixed = model.selectedProfile?.fixedSize ?? .standard
        return Section {
            Picker(
                Localization.text(.profileDisplayMode),
                selection: Binding(get: { mode }, set: { mode in model.update { $0.displayMode = mode } })
            ) {
                ForEach(ProfileDisplayMode.allCases) { mode in
                    Text(Localization.text(Self.title(of: mode))).tag(mode)
                }
            }
            if mode != .fixed {
                Toggle(Localization.text(.profileDisplaySharp), isOn: flag(\.sharpOnRetina))
            }
            if mode == .fixed {
                // A size not in the list shows as the custom one; choosing it keeps the size for the fields below
                Picker(
                    Localization.text(.profileDisplaySize),
                    selection: Binding<DesktopSize?>(
                        get: { DesktopSize.presets.contains(fixed) ? fixed : nil },
                        set: { size in
                            if let size {
                                model.update { $0.fixedSize = size }
                            }
                        })
                ) {
                    ForEach(DesktopSize.presets, id: \.self) { size in
                        Text(Self.label(of: size)).tag(Optional(size))
                    }
                    Text(Localization.text(.profileDisplayCustom)).tag(DesktopSize?.none)
                }
                TextField(
                    Localization.text(.profileDisplayWidth),
                    value: side(\.width), format: .number.grouping(.never))
                TextField(
                    Localization.text(.profileDisplayHeight),
                    value: side(\.height), format: .number.grouping(.never))
            }
        } header: {
            Text(Localization.text(.profileDisplaySection))
        } footer: {
            Text(Self.hint(of: mode))
        }
    }

    /// A side of the fixed size; what is typed goes within the limits of the protocol as it is saved
    private func side(_ keyPath: WritableKeyPath<DesktopSize, Int>) -> Binding<Int> {
        Binding(
            get: { model.selectedProfile?.fixedSize[keyPath: keyPath] ?? DesktopSize.standard[keyPath: keyPath] },
            set: { value in
                model.update { profile in
                    var size = profile.fixedSize
                    size[keyPath: keyPath] = value
                    profile.fixedSize = size.clamped
                }
            })
    }

    private static func label(of size: DesktopSize) -> String {
        "\(size.width) × \(size.height)"
    }

    private static func title(of mode: ProfileDisplayMode) -> TextKey {
        switch mode {
        case .window: .profileDisplayWindow
        case .maximized: .profileDisplayMaximized
        case .fullScreen: .profileDisplayFullScreen
        case .fixed: .profileDisplayFixed
        }
    }

    private static func hint(of mode: ProfileDisplayMode) -> String {
        switch mode {
        case .window: Localization.text(.profileDisplayWindowHint)
        case .maximized: Localization.text(.profileDisplayMaximizedHint)
        case .fullScreen: Localization.text(.profileDisplayFullScreenHint)
        case .fixed:
            Localization.text(
                .profileDisplayFixedHint,
                ["min": String(DesktopSize.minimumSide), "max": String(DesktopSize.maximumSide)])
        }
    }

    private func field(_ keyPath: WritableKeyPath<ConnectionProfile, String>) -> Binding<String> {
        Binding(
            get: { model.selectedProfile?[keyPath: keyPath] ?? "" },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }

    private func flag(_ keyPath: WritableKeyPath<ConnectionProfile, Bool>) -> Binding<Bool> {
        Binding(
            get: { model.selectedProfile?[keyPath: keyPath] ?? false },
            set: { value in model.update { $0[keyPath: keyPath] = value } })
    }

    private static func title(of keyboard: ProfileKeyboard) -> TextKey {
        switch keyboard {
        case .settings: .profileKeyboardSettings
        case .mac: .settingsKeyboardPresetMac
        case .pc: .settingsKeyboardPresetPC
        }
    }
}
