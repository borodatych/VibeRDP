import SwiftUI

/// The main window, as Windows App lays it out: the sections on the left, the connections as tiles or rows,
/// the toolbar with a new connection, the layout, the order and the search; a connection is edited in a sheet
struct ConnectionsView: View {
    static let sidebarWidth: CGFloat = 220
    static let editorSize = CGSize(width: 560, height: 640)

    @Bindable var model: ConnectionsModel
    /// The profile the user asked to delete, while the question is open
    @State private var deleting: ConnectionProfile?

    var body: some View {
        NavigationSplitView {
            List(selection: sectionSelection) {
                Label(Localization.text(.connectionsSidebarFavorites), systemImage: "star")
                    .tag(ConnectionsSection.favorites)
                Label(Localization.text(.connectionsSidebarAll), systemImage: "display")
                    .tag(ConnectionsSection.all)
            }
            .navigationSplitViewColumnWidth(Self.sidebarWidth)
        } detail: {
            VStack(spacing: 0) {
                ConnectionsContent(model: model, deleting: $deleting)
                if !model.status.isEmpty {
                    Divider()
                    Text(model.status)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal)
                        .padding(.vertical, 8)
                }
            }
            .toolbar { toolbar }
            .searchable(
                text: $model.searchText, placement: .toolbar, prompt: Localization.text(.connectionsSearchPrompt))
        }
        .sheet(item: editingProfile) { _ in
            VStack(spacing: 0) {
                ProfileEditor(model: model)
                Divider()
                HStack {
                    Spacer()
                    Button(Localization.text(.connectionsEditDone)) {
                        model.editing = nil
                    }
                    .keyboardShortcut(.defaultAction)
                }
                .padding()
            }
            .frame(width: Self.editorSize.width, height: Self.editorSize.height)
        }
        .confirmationDialog(
            Localization.text(.connectionsDeleteQuestion, ["name": deleting.map(Self.title(of:)) ?? ""]),
            isPresented: Binding(get: { deleting != nil }, set: { if !$0 { deleting = nil } })
        ) {
            Button(Localization.text(.connectionsRemove), role: .destructive) {
                if let deleting {
                    model.delete(deleting.id)
                }
                deleting = nil
            }
            Button(Localization.text(.connectionsDeleteCancel), role: .cancel) {
                deleting = nil
            }
        } message: {
            Text(Localization.text(.connectionsDeleteMessage))
        }
    }

    @ToolbarContentBuilder
    private var toolbar: some ToolbarContent {
        ToolbarItem {
            Button {
                model.addAndEdit()
            } label: {
                Label(Localization.text(.connectionsAdd), systemImage: "plus")
            }
            .help(Localization.text(.connectionsAdd))
            .disabled(model.isBusy)
        }
        ToolbarItem {
            Picker(Localization.text(.connectionsLayoutGrid), selection: $model.layout) {
                Label(Localization.text(.connectionsLayoutGrid), systemImage: "square.grid.2x2")
                    .tag(ConnectionsLayout.grid)
                Label(Localization.text(.connectionsLayoutList), systemImage: "list.bullet")
                    .tag(ConnectionsLayout.list)
            }
            .pickerStyle(.segmented)
        }
        ToolbarItem {
            Menu {
                Picker(Localization.text(.connectionsSortLabel), selection: $model.sort) {
                    Text(Localization.text(.connectionsSortManual)).tag(ConnectionsSort.manual)
                    Text(Localization.text(.connectionsSortName)).tag(ConnectionsSort.name)
                    Text(Localization.text(.connectionsSortLastConnected)).tag(ConnectionsSort.lastConnected)
                }
                .pickerStyle(.inline)
            } label: {
                Label(Localization.text(.connectionsSortLabel), systemImage: "arrow.up.arrow.down")
            }
            .help(Localization.text(.connectionsSortLabel))
        }
    }

    /// The sidebar always has a section: a click on empty space would otherwise clear it
    private var sectionSelection: Binding<ConnectionsSection?> {
        Binding(get: { model.section }, set: { section in model.section = section ?? model.section })
    }

    private var editingProfile: Binding<EditedProfile?> {
        Binding(
            get: { model.editing.map(EditedProfile.init) },
            set: { model.editing = $0?.id })
    }

    static func title(of profile: ConnectionProfile) -> String {
        profile.title.isEmpty ? Localization.text(.connectionsUntitled) : profile.title
    }
}

/// The profile of the edit sheet, as the sheet needs an identifiable item
private struct EditedProfile: Identifiable {
    let id: UUID
}

/// The connections of the section: tiles or rows, or what to do when there are none
/// A tile is dragged as an icon in the Dock is: it lifts and follows the pointer, and the others make way for it
private struct ConnectionsContent: View {
    static let tileMinimumWidth: CGFloat = 260
    static let tileMaximumWidth: CGFloat = 360
    static let spacing: CGFloat = 20
    /// How far the pointer moves before a press becomes a drag, so a click stays a click
    static let dragThreshold: CGFloat = 8
    /// The lifted tile: a little larger than the others, with a shadow
    static let liftScale: CGFloat = 1.06
    static let liftShadow: CGFloat = 18
    static let tiles = "tiles"
    /// The others make way with a spring, as icons do
    static let makeWay = Animation.spring(response: 0.35, dampingFraction: 0.78)

    @Bindable var model: ConnectionsModel
    @Binding var deleting: ConnectionProfile?
    /// The tile being dragged, where the pointer is and where it held the tile, in the space of the grid
    @State private var dragged: UUID?
    @State private var pointer: CGPoint = .zero
    @State private var grab: CGSize = .zero
    /// Where each tile stands now in the grid, as the layout reports it
    @State private var frames: [UUID: CGRect] = [:]
    /// A change of places waits for the layout to report the new ones
    @State private var awaitingLayout = false
    /// The lifted copy lands in its place as the drag ends
    @State private var settling = false

    var body: some View {
        let profiles = model.visibleProfiles
        if model.store.profiles.isEmpty {
            ContentUnavailableView {
                Label(Localization.text(.connectionsEmptyTitle), systemImage: "display")
            } description: {
                Text(Localization.text(.connectionsEmptyMessage))
            } actions: {
                Button(Localization.text(.connectionsAdd)) {
                    model.addAndEdit()
                }
                if model.windowsAppInstalled {
                    Button(Localization.text(.connectionsWindowsAppOffer)) {
                        model.importWindowsApp()
                    }
                }
            }
        } else if profiles.isEmpty {
            if model.searchText.isEmpty {
                ContentUnavailableView(
                    Localization.text(.connectionsFavoritesEmptyTitle), systemImage: "star",
                    description: Text(Localization.text(.connectionsFavoritesEmptyMessage)))
            } else {
                ContentUnavailableView(Localization.text(.connectionsSearchEmpty), systemImage: "magnifyingglass")
            }
        } else if model.layout == .grid {
            ScrollView {
                VStack(alignment: .leading, spacing: Self.spacing) {
                    Text(Localization.text(model.section == .all ? .connectionsSaved : .connectionsSidebarFavorites))
                        .font(.title2.bold())
                    LazyVGrid(
                        columns: [
                            GridItem(
                                .adaptive(minimum: Self.tileMinimumWidth, maximum: Self.tileMaximumWidth),
                                spacing: Self.spacing, alignment: .top)
                        ],
                        alignment: .leading, spacing: Self.spacing
                    ) {
                        ForEach(profiles) { profile in
                            tile(profile)
                        }
                    }
                    .coordinateSpace(name: Self.tiles)
                    .onPreferenceChange(TileFrames.self) { reported in
                        frames = reported
                        awaitingLayout = false
                    }
                    .overlay(alignment: .topLeading) { liftedTile }
                }
                .padding(Self.spacing)
            }
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(.return) {
                model.connect()
                return .handled
            }
        } else {
            List(selection: $model.selection) {
                ForEach(profiles) { profile in
                    ConnectionRow(model: model, profile: profile)
                        .tag(profile.id)
                }
                // A row dragged between others takes the place it is dropped at, as a tile does
                .onMove { sources, destination in
                    guard let source = sources.first,
                        let target = ConnectionsModel.target(moving: source, to: destination, in: profiles)
                    else { return }
                    model.move(profiles[source].id, to: target)
                }
            }
            // Double-click or Return on a row connects, as in the Finder a double-click opens
            .contextMenu(forSelectionType: UUID.self) { ids in
                if let id = ids.first, let profile = model.store.profile(id) {
                    ConnectionMenu(model: model, profile: profile, deleting: $deleting)
                }
            } primaryAction: { ids in
                if let id = ids.first {
                    model.connect(id)
                }
            }
        }
    }
}

extension ConnectionsContent {
    /// A tile with its clicks, its menu and its drag; while dragged it stays as an empty place among the others,
    /// and its lifted copy over the grid follows the pointer
    private func tile(_ profile: ConnectionProfile) -> some View {
        ConnectionTile(model: model, profile: profile)
            .background {
                GeometryReader { geometry in
                    Color.clear.preference(
                        key: TileFrames.self, value: [profile.id: geometry.frame(in: .named(Self.tiles))])
                }
            }
            .opacity(dragged == profile.id ? 0 : 1)
            .onTapGesture(count: 2) { model.connect(profile.id) }
            .onTapGesture { model.selection = profile.id }
            .gesture(drag(profile))
            .contextMenu { ConnectionMenu(model: model, profile: profile, deleting: $deleting) }
    }

    /// The lifted copy of the dragged tile: placed by the pointer alone, so a change of places under it never
    /// moves it; as the drag ends it settles into its place and gives way to the tile itself
    @ViewBuilder
    private var liftedTile: some View {
        if let id = dragged, let profile = model.store.profile(id), let slot = frames[id] {
            ConnectionTile(model: model, profile: profile)
                .frame(width: slot.width, height: slot.height)
                .scaleEffect(settling ? 1 : Self.liftScale)
                .shadow(color: .black.opacity(settling ? 0 : 0.45), radius: settling ? 0 : Self.liftShadow)
                .position(x: pointer.x - grab.width, y: pointer.y - grab.height)
                .allowsHitTesting(false)
        }
    }

    private func drag(_ profile: ConnectionProfile) -> some Gesture {
        DragGesture(minimumDistance: Self.dragThreshold, coordinateSpace: .named(Self.tiles))
            .onChanged { value in
                if dragged == nil, let slot = frames[profile.id] {
                    model.selection = profile.id
                    grab = CGSize(width: value.startLocation.x - slot.midX, height: value.startLocation.y - slot.midY)
                    pointer = value.startLocation
                    settling = false
                    dragged = profile.id
                }
                guard dragged == profile.id else { return }
                pointer = value.location
                // Until the layout reports the places after a change, the old ones would send the tile back
                guard !awaitingLayout else { return }
                // The tile under the pointer gives its place; the others shift by one toward the gap
                let under = frames.first { $0.key != profile.id && $0.value.contains(value.location) }
                if let target = under?.key {
                    awaitingLayout = true
                    withAnimation(Self.makeWay) { model.move(profile.id, to: target) }
                }
            }
            .onEnded { _ in
                guard dragged == profile.id, let slot = frames[profile.id] else {
                    dragged = nil
                    return
                }
                withAnimation(Self.makeWay) {
                    pointer = CGPoint(x: slot.midX + grab.width, y: slot.midY + grab.height)
                    settling = true
                } completion: {
                    dragged = nil
                    settling = false
                }
            }
    }
}

/// Where each tile stands in the grid, gathered from the tiles
private struct TileFrames: PreferenceKey {
    static let defaultValue: [UUID: CGRect] = [:]

    static func reduce(value: inout [UUID: CGRect], nextValue: () -> [UUID: CGRect]) {
        value.merge(nextValue()) { _, new in new }
    }
}

/// What can be done with one connection, from its tile or its row
private struct ConnectionMenu: View {
    let model: ConnectionsModel
    let profile: ConnectionProfile
    @Binding var deleting: ConnectionProfile?

    var body: some View {
        Button(Localization.text(.connectionActionConnect)) {
            model.connect(profile.id)
        }
        .disabled(model.isBusy)
        Button(Localization.text(.connectionsActionEdit)) {
            model.edit(profile.id)
        }
        .disabled(model.isBusy)
        Button(Localization.text(profile.isFavorite ? .connectionsActionUnfavorite : .connectionsActionFavorite)) {
            model.toggleFavorite(profile.id)
        }
        Divider()
        Button(Localization.text(.connectionsRemove), role: .destructive) {
            deleting = profile
        }
        .disabled(model.isBusy && model.activeProfile == profile.id)
    }
}

/// A connection as a tile: its last picture or the art of VibeRDP, the name over it, and the session while it runs
private struct ConnectionTile: View {
    static let aspectRatio: CGFloat = 16 / 10
    static let cornerRadius: CGFloat = 14

    let model: ConnectionsModel
    let profile: ConnectionProfile

    var body: some View {
        let selected = model.selection == profile.id
        let running = model.isBusy && model.activeProfile == profile.id
        ZStack(alignment: .bottomLeading) {
            picture
            LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .center, endPoint: .bottom)
            VStack(alignment: .leading, spacing: 2) {
                Text(ConnectionsView.title(of: profile))
                    .font(.title3.bold())
                if !profile.username.isEmpty {
                    Text(profile.username)
                        .font(.callout)
                }
            }
            .foregroundStyle(.white)
            .lineLimit(1)
            .padding(14)
        }
        .overlay(alignment: .topLeading) {
            HStack(spacing: 6) {
                Text(Localization.text(.connectionsTileBadge))
                if profile.isFavorite {
                    Image(systemName: "star.fill")
                }
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 6))
            .padding(12)
        }
        .overlay {
            if running {
                ZStack {
                    Color.black.opacity(0.55)
                    VStack(spacing: 10) {
                        ProgressView()
                            .controlSize(.regular)
                        Button(Localization.text(.connectionsTileCancel)) {
                            model.disconnect()
                        }
                    }
                }
            }
        }
        .aspectRatio(Self.aspectRatio, contentMode: .fit)
        .clipShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .overlay {
            RoundedRectangle(cornerRadius: Self.cornerRadius)
                .strokeBorder(selected ? Color.accentColor : .white.opacity(0.08), lineWidth: selected ? 3 : 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: Self.cornerRadius))
        .help(profile.address)
    }

    @ViewBuilder
    private var picture: some View {
        // The revision is read so a new picture redraws the tile
        let _ = model.snapshotRevision
        if let image = model.snapshots.image(for: profile.id) {
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
        } else {
            TileArt(seed: profile.id)
        }
    }
}

/// A connection as a row: a small picture, the name and the address, the user at the end
private struct ConnectionRow: View {
    static let pictureSize = CGSize(width: 64, height: 40)

    let model: ConnectionsModel
    let profile: ConnectionProfile

    var body: some View {
        HStack(spacing: 12) {
            Group {
                let _ = model.snapshotRevision
                if let image = model.snapshots.image(for: profile.id) {
                    Image(nsImage: image)
                        .resizable()
                        .scaledToFill()
                } else {
                    TileArt(seed: profile.id)
                }
            }
            .frame(width: Self.pictureSize.width, height: Self.pictureSize.height)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(ConnectionsView.title(of: profile))
                    if profile.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundStyle(.secondary)
                    }
                }
                if !profile.name.isEmpty && !profile.address.isEmpty {
                    Text(profile.address)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if model.isBusy && model.activeProfile == profile.id {
                ProgressView()
                    .controlSize(.small)
            }
            Text(profile.username)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }
}

/// The picture of a connection before its first session: waves in the colours of the VibeRDP icon over its dark,
/// shifted by the id, so the tiles differ
struct TileArt: View {
    /// The colours of the icon: its dark ground, its violet and its light violet
    static let ground = Color(red: 0x1A / 255, green: 0x12 / 255, blue: 0x33 / 255)
    static let violet = Color(red: 0x92 / 255, green: 0x77 / 255, blue: 0xFF / 255)
    static let light = Color(red: 0xBB / 255, green: 0xA8 / 255, blue: 0xFF / 255)

    let seed: UUID

    var body: some View {
        let phase = Double(seed.uuid.0) / 255
        Canvas { context, size in
            context.fill(
                Path(CGRect(origin: .zero, size: size)),
                with: .linearGradient(
                    Gradient(colors: [Self.ground, .black]), startPoint: .zero,
                    endPoint: CGPoint(x: size.width, y: size.height)))
            let waves: [(Color, Double, Double)] = [
                (Self.violet, 0.55, 0.45), (Self.light, 0.35, 0.3), (Self.violet, 0.8, 0.6),
            ]
            for (index, wave) in waves.enumerated() {
                let (color, level, opacity) = wave
                var path = Path()
                path.move(to: CGPoint(x: 0, y: size.height))
                for step in 0...48 {
                    let x = size.width * Double(step) / 48
                    let angle = (Double(step) / 48 + phase + Double(index) * 0.21) * .pi * 2
                    let y = size.height * (level - 0.18 * sin(angle) - 0.25 * Double(step) / 48)
                    path.addLine(to: CGPoint(x: x, y: y))
                }
                path.addLine(to: CGPoint(x: size.width, y: size.height))
                path.closeSubpath()
                context.fill(
                    path,
                    with: .linearGradient(
                        Gradient(colors: [color.opacity(opacity), color.opacity(0.05)]),
                        startPoint: CGPoint(x: size.width, y: 0), endPoint: CGPoint(x: 0, y: size.height)))
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
