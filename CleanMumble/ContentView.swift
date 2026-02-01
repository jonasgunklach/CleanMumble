//
//  ContentView.swift
//  CleanMumble
//

import SwiftUI

// MARK: - Root

struct ContentView: View {
    @StateObject private var viewModel = MumbleViewModel()
    @State private var showAddServer = false
    @State private var showSettings  = false

    var body: some View {
        NavigationSplitView {
            SidebarView(showAddServer: $showAddServer)
                .environmentObject(viewModel)
        } detail: {
            DetailView(showSettings: $showSettings)
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showAddServer) {
            AddServerView()
                .environmentObject(viewModel)
        }
        .sheet(isPresented: $showSettings) {
            SettingsView()
                .environmentObject(viewModel)
                .frame(minWidth: 480, minHeight: 420)
        }
        .preferredColorScheme(viewModel.userPreferences.theme.colorScheme)
    }
}

// MARK: - Sidebar

enum ChannelFilter: String, CaseIterable {
    case all       = "All Channels"
    case hasUsers  = "Has Users"
    case topLevel  = "Top Level Only"
}

struct SidebarView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    @Binding var showAddServer: Bool
    @State private var channelFilter: ChannelFilter = .all

    /// Channel IDs that pass the current filter (nil = all pass).
    private var visibleIds: Set<Int32>? {
        guard channelFilter == .hasUsers else { return nil }
        func subtreeHasUsers(_ id: Int32) -> Bool {
            if viewModel.users.contains(where: { $0.currentChannelId == id }) { return true }
            return viewModel.channels
                .filter { $0.parentChannelId == id }
                .contains { subtreeHasUsers($0.channelId) }
        }
        return Set(viewModel.channels.filter { subtreeHasUsers($0.channelId) }.map { $0.channelId })
    }

    var body: some View {
        VStack(spacing: 0) {
            List {
                Section {
                    ForEach(viewModel.servers) { server in
                        ServerSidebarRow(server: server)
                            .environmentObject(viewModel)
                    }
                } header: {
                    Text("SERVERS")
                        .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                }

                if viewModel.isConnected {
                    Section {
                        ForEach(viewModel.rootChannels) { ch in
                            SidebarChannelItem(
                                channel: ch,
                                channels: viewModel.channels,
                                users: viewModel.users,
                                filter: channelFilter,
                                visibleIds: visibleIds
                            )
                            .environmentObject(viewModel)
                        }
                    } header: {
                        HStack(spacing: 4) {
                            Circle().fill(Color.green).frame(width: 7, height: 7)
                            Text(viewModel.currentServer?.name ?? "Connected")
                                .font(.caption).fontWeight(.semibold).foregroundColor(.secondary)
                        }
                    }
                }
            }
            .listStyle(.sidebar)

            if viewModel.isConnected {
                SidebarAudioStrip()
                    .environmentObject(viewModel)
            }
        }
        .navigationTitle("CleanMumble")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button { showAddServer = true } label: { Image(systemName: "plus") }
                    .help("Add Server")
            }
            ToolbarItem(placement: .primaryAction) {
                Menu {
                    ForEach(ChannelFilter.allCases, id: \.self) { f in
                        Button {
                            channelFilter = f
                        } label: {
                            if channelFilter == f {
                                Label(f.rawValue, systemImage: "checkmark")
                            } else {
                                Text(f.rawValue)
                            }
                        }
                    }
                } label: {
                    Image(systemName: channelFilter == .all
                          ? "line.3.horizontal.decrease.circle"
                          : "line.3.horizontal.decrease.circle.fill")
                }
                .help("Filter channels")
                .disabled(!viewModel.isConnected)
            }
        }
    }
}

// MARK: - Server row

struct ServerSidebarRow: View {
    let server: ServerConnectionInfo
    @EnvironmentObject var viewModel: MumbleViewModel

    private var isActive: Bool {
        viewModel.isConnected && viewModel.currentServer?.id == server.id
    }

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(isActive ? Color.green : Color.secondary.opacity(0.35))
                .frame(width: 8, height: 8)
            VStack(alignment: .leading, spacing: 1) {
                Text(server.name)
                    .font(.body)
                    .fontWeight(isActive ? .semibold : .regular)
                Text("\(server.host):\(server.port)")
                    .font(.caption2).foregroundColor(.secondary)
            }
            Spacer()
            if server.isFavorite {
                Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption2)
            }
        }
        .padding(.vertical, 2)
        .contentShape(Rectangle())
        .onTapGesture {
            if isActive { viewModel.disconnect() }
            else        { viewModel.connectToServer(server) }
        }
        .contextMenu {
            if !isActive {
                Button { viewModel.connectToServer(server) } label: {
                    Label("Connect", systemImage: "play.circle")
                }
            } else {
                Button { viewModel.disconnect() } label: {
                    Label("Disconnect", systemImage: "xmark.circle")
                }
            }
            Divider()
            Button { viewModel.toggleFavorite(server) } label: {
                Label(server.isFavorite ? "Remove Favorite" : "Mark as Favorite",
                      systemImage: server.isFavorite ? "star.slash" : "star")
            }
            Button(role: .destructive) { viewModel.removeServer(server) } label: {
                Label("Remove", systemImage: "trash")
            }
        }
    }
}

// MARK: - Channel tree

struct SidebarChannelItem: View {
    let channel:    ChannelInfo
    let channels:   [ChannelInfo]
    let users:      [UserInfo]
    let filter:     ChannelFilter
    let visibleIds: Set<Int32>?   // nil = all visible
    @EnvironmentObject var viewModel: MumbleViewModel
    @State private var expanded = true

    private var usersHere: [UserInfo] {
        users.filter { $0.currentChannelId == channel.channelId }
    }
    private var children: [ChannelInfo] {
        guard filter != .topLevel else { return [] }
        let all = channels.filter { $0.parentChannelId == channel.channelId }
                          .sorted { $0.channelId < $1.channelId }
        guard let ids = visibleIds else { return all }
        return all.filter { ids.contains($0.channelId) }
    }
    private var isCurrent: Bool {
        viewModel.currentChannel?.channelId == channel.channelId
    }

    var body: some View {
        DisclosureGroup(isExpanded: $expanded) {
            ForEach(usersHere) { user in
                SidebarUserRow(user: user).padding(.leading, 2)
            }
            ForEach(children) { child in
                SidebarChannelItem(channel: child, channels: channels, users: users,
                                   filter: filter, visibleIds: visibleIds)
                    .environmentObject(viewModel)
            }
        } label: {
            HStack(spacing: 6) {
                Image(systemName: channelIcon(channel.name))
                    .foregroundColor(isCurrent ? .accentColor : .secondary)
                    .font(.caption).frame(width: 14)
                Text(channel.name)
                    .font(.body)
                    .fontWeight(isCurrent ? .semibold : .regular)
                    .foregroundColor(isCurrent ? .accentColor : .primary)
                Spacer()
                if !usersHere.isEmpty {
                    Text("\(usersHere.count)")
                        .font(.caption2).foregroundColor(.secondary)
                }
            }
        }
        .onTapGesture(count: 2) { viewModel.joinChannel(channel) }
        .contextMenu {
            Button { viewModel.joinChannel(channel) } label: {
                Label("Join Channel", systemImage: "arrow.right.circle")
            }
        }
    }

    private func channelIcon(_ name: String) -> String {
        let n = name.lowercased()
        if n.contains("afk")   { return "moon.zzz" }
        if n.contains("lobby") || n.contains("root") { return "house" }
        if n.contains("music") { return "music.note" }
        if n.contains("game")  { return "gamecontroller" }
        return "number"
    }
}

struct SidebarUserRow: View {
    let user: UserInfo

    var body: some View {
        HStack(spacing: 6) {
            ZStack {
                Circle()
                    .fill(user.isSpeaking ? Color.green : Color.accentColor.opacity(0.4))
                    .frame(width: 20, height: 20)
                Text(String(user.name.prefix(1)).uppercased())
                    .font(.system(size: 9, weight: .bold)).foregroundColor(.white)
            }
            Text(user.name)
                .font(.subheadline)
                .foregroundColor((user.isMuted || user.isSelfMuted) ? .secondary : .primary)
                .lineLimit(1)
            Spacer()
            HStack(spacing: 2) {
                if user.isMuted || user.isSelfMuted {
                    Image(systemName: "mic.slash.fill").font(.caption2).foregroundColor(.red)
                }
                if user.isDeafened || user.isSelfDeafened {
                    Image(systemName: "speaker.slash.fill").font(.caption2).foregroundColor(.orange)
                }
                if user.isSpeaking {
                    Image(systemName: "waveform").font(.caption2).foregroundColor(.green)
                }
            }
        }
    }
}

// MARK: - Audio strip (Discord-style bottom bar)

struct SidebarAudioStrip: View {
    @EnvironmentObject var viewModel: MumbleViewModel

    var body: some View {
        VStack(spacing: 0) {
            Divider()
            HStack(spacing: 8) {
                ZStack {
                    Circle()
                        .fill(viewModel.isSpeaking ? Color.green : Color.accentColor.opacity(0.5))
                        .frame(width: 28, height: 28)
                    Text(String((viewModel.currentServer?.username ?? "?").prefix(1)).uppercased())
                        .font(.caption).fontWeight(.bold).foregroundColor(.white)
                }
                VStack(alignment: .leading, spacing: 1) {
                    Text(viewModel.currentServer?.username ?? "Unknown")
                        .font(.subheadline).fontWeight(.medium).lineLimit(1)
                    Group {
                        if viewModel.isMuted        { Text("Muted").foregroundColor(.red) }
                        else if viewModel.isSpeaking { Text("Speaking").foregroundColor(.green) }
                        else                         { Text("Connected").foregroundColor(.secondary) }
                    }
                    .font(.caption2)
                }
                Spacer()
                Button { viewModel.toggleMute() } label: {
                    Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                        .font(.body)
                        .foregroundColor(viewModel.isMuted ? .red : .primary)
                }
                .buttonStyle(.plain)
                .help(viewModel.isMuted ? "Unmute" : "Mute")

                Button { viewModel.toggleDeafen() } label: {
                    Image(systemName: viewModel.isDeafened ? "speaker.slash.fill" : "headphones")
                        .font(.body)
                        .foregroundColor(viewModel.isDeafened ? .orange : .primary)
                }
                .buttonStyle(.plain)
                .help(viewModel.isDeafened ? "Undeafen" : "Deafen")
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
        }
        .background(Color(NSColor.windowBackgroundColor))
    }
}

// MARK: - Detail area

struct DetailView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    @Binding var showSettings: Bool
    @State private var showInputVol  = false
    @State private var showOutputVol = false

    var body: some View {
        Group {
            if viewModel.isConnected {
                ChatView().environmentObject(viewModel)
            } else {
                DisconnectedView().environmentObject(viewModel)
            }
        }
        .navigationTitle(navTitle)
        .toolbar {
            if viewModel.isConnected {
                ToolbarItemGroup(placement: .primaryAction) {
                    Button { showInputVol.toggle() } label: {
                        Image(systemName: viewModel.isMuted ? "mic.slash.fill" : "mic.fill")
                            .foregroundColor(viewModel.isMuted ? .red : .primary)
                    }
                    .help("Input volume")
                    .popover(isPresented: $showInputVol, arrowEdge: .bottom) {
                        VolumePopover(
                            title: "Input Volume", icon: "mic.fill",
                            volume: Binding(
                                get: { viewModel.inputVolume },
                                set: { viewModel.setInputVolume($0) }
                            )
                        )
                    }

                    Button { showOutputVol.toggle() } label: {
                        Image(systemName: viewModel.outputVolume == 0
                              ? "speaker.slash.fill" : "speaker.wave.2.fill")
                    }
                    .help("Output volume")
                    .popover(isPresented: $showOutputVol, arrowEdge: .bottom) {
                        VolumePopover(
                            title: "Output Volume", icon: "speaker.wave.2.fill",
                            volume: Binding(
                                get: { viewModel.outputVolume },
                                set: { viewModel.setOutputVolume($0) }
                            )
                        )
                    }

                    Divider()

                    Button { showSettings = true } label: { Image(systemName: "gear") }
                        .help("Settings")

                    Button { viewModel.disconnect() } label: {
                        Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                    }
                    .help("Disconnect")
                }
            } else {
                ToolbarItem(placement: .primaryAction) {
                    Button { showSettings = true } label: { Image(systemName: "gear") }
                        .help("Settings")
                }
            }
        }
    }

    private var navTitle: String {
        guard viewModel.isConnected else { return "CleanMumble" }
        if let ch = viewModel.currentChannel { return "# \(ch.name)" }
        return viewModel.currentServer?.name ?? "Connected"
    }
}

struct VolumePopover: View {
    let title:  String
    let icon:   String
    @Binding var volume: Float

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label(title, systemImage: icon).font(.headline)
            HStack(spacing: 6) {
                Image(systemName: "speaker").foregroundColor(.secondary).font(.caption)
                Slider(value: $volume, in: 0...1).frame(width: 160)
                Image(systemName: "speaker.wave.3").foregroundColor(.secondary).font(.caption)
            }
            Text("\(Int(volume * 100))%")
                .font(.caption).foregroundColor(.secondary)
                .frame(maxWidth: .infinity, alignment: .center)
        }
        .padding()
        .frame(width: 240)
    }
}

// MARK: - Disconnected placeholder

struct DisconnectedView: View {
    @EnvironmentObject var viewModel: MumbleViewModel

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Image(systemName: "waveform.slash")
                .font(.system(size: 52)).foregroundColor(.secondary)
                .padding(.bottom, 12)
            Text("Not Connected")
                .font(.title2).fontWeight(.semibold)
            Text("Select a server below or in the sidebar.")
                .font(.body).foregroundColor(.secondary)
                .padding(.bottom, 28)

            if !viewModel.servers.isEmpty {
                VStack(spacing: 8) {
                    ForEach(viewModel.servers) { server in
                        QuickConnectRow(server: server)
                            .environmentObject(viewModel)
                    }
                }
                .frame(maxWidth: 380)
            }
            Spacer()
        }
        .padding(.horizontal, 32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct QuickConnectRow: View {
    let server: ServerConnectionInfo
    @EnvironmentObject var viewModel: MumbleViewModel

    var body: some View {
        HStack(spacing: 12) {
            ZStack {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.accentColor.opacity(0.12))
                    .frame(width: 36, height: 36)
                Image(systemName: "server.rack")
                    .foregroundColor(.accentColor).font(.body)
            }
            VStack(alignment: .leading, spacing: 2) {
                Text(server.name).font(.body).fontWeight(.medium)
                Text("\(server.host):\(server.port)")
                    .font(.caption).foregroundColor(.secondary)
            }
            Spacer()
            if server.isFavorite {
                Image(systemName: "star.fill").foregroundColor(.yellow).font(.caption)
            }
            Button("Connect") { viewModel.connectToServer(server) }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(10)
    }
}

#Preview {
    ContentView()
}
