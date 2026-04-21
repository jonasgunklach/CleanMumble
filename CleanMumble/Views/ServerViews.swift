//
//  ServerViews.swift
//  CleanMumble
//

import SwiftUI

// MARK: - Add Server sheet

struct AddServerView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var viewModel: MumbleViewModel

    @State private var name       = ""
    @State private var host       = ""
    @State private var port       = "64738"
    @State private var username   = ""
    @State private var password   = ""
    @State private var isFavorite = false

    private var canAdd: Bool { !name.isEmpty && !host.isEmpty && !username.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                        .textContentType(.URL)
                    TextField("Port", text: $port)
                }
                Section("Account") {
                    TextField("Username", text: $username)
                    SecureField("Password (optional)", text: $password)
                    Toggle("Favorite", isOn: $isFavorite)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Add Server") { addServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canAdd)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 360)
        .navigationTitle("Add Server")
    }

    private func addServer() {
        viewModel.addServer(ServerConnectionInfo(
            name: name,
            host: host,
            port: Int(port) ?? 64738,
            username: username,
            password: password,
            isFavorite: isFavorite
        ))
        dismiss()
    }
}

// MARK: - Edit Server sheet

struct EditServerView: View {
    @Environment(\..dismiss) private var dismiss
    @EnvironmentObject var viewModel: MumbleViewModel

    let server: ServerConnectionInfo

    @State private var name: String
    @State private var host: String
    @State private var port: String
    @State private var username: String
    @State private var password: String
    @State private var isFavorite: Bool

    init(server: ServerConnectionInfo) {
        self.server = server
        _name       = State(initialValue: server.name)
        _host       = State(initialValue: server.host)
        _port       = State(initialValue: String(server.port))
        _username   = State(initialValue: server.username)
        _password   = State(initialValue: server.password)
        _isFavorite = State(initialValue: server.isFavorite)
    }

    private var canSave: Bool { !name.isEmpty && !host.isEmpty && !username.isEmpty }

    var body: some View {
        VStack(spacing: 0) {
            Form {
                Section("Server") {
                    TextField("Name", text: $name)
                    TextField("Host", text: $host)
                        .textContentType(.URL)
                    TextField("Port", text: $port)
                }
                Section("Account") {
                    TextField("Username", text: $username)
                    SecureField("Password (optional)", text: $password)
                    Toggle("Favorite", isOn: $isFavorite)
                }
            }
            .formStyle(.grouped)
            .scrollDisabled(true)

            Divider()

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save") { saveServer() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canSave)
            }
            .padding(.horizontal, 20)
            .padding(.vertical, 12)
        }
        .frame(width: 360)
        .navigationTitle("Edit Server")
    }

    private func saveServer() {
        var updated = server
        updated.name       = name
        updated.host       = host
        updated.port       = Int(port) ?? 64738
        updated.username   = username
        updated.password   = password
        updated.isFavorite = isFavorite
        viewModel.updateServer(updated)
        // If editing the currently-active server, refresh currentServer so the
        // sidebar header and audio strip reflect the new name/username.
        if viewModel.currentServer?.id == server.id {
            viewModel.currentServer = updated
        }
        dismiss()
    }
}

// MARK: - Legacy views kept for compatibility

struct ServerRowView: View {
    let server: ServerConnectionInfo
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(server.name)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Spacer()
                    
                    if server.isFavorite {
                        Image(systemName: "star.fill")
                            .foregroundColor(.yellow)
                            .font(.caption)
                    }
                }
                
                HStack {
                    Text(server.host)
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    Spacer()
                    
                    if let lastConnected = server.lastConnected {
                        Text("Last: \(lastConnected, style: .relative)")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                }
            }
            
            Spacer()
            
            Button(action: {
                if viewModel.isConnected && viewModel.currentServer?.id == server.id {
                    viewModel.disconnect()
                } else {
                    viewModel.connectToServer(server)
                }
            }) {
                Image(systemName: viewModel.isConnected && viewModel.currentServer?.id == server.id ? "stop.circle.fill" : "play.circle.fill")
                    .foregroundColor(viewModel.isConnected && viewModel.currentServer?.id == server.id ? .red : .green)
                    .font(.title2)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            if !viewModel.isConnected {
                viewModel.connectToServer(server)
            }
        }
        .contextMenu {
            Button(action: { viewModel.toggleFavorite(server) }) {
                Label(server.isFavorite ? "Remove from Favorites" : "Add to Favorites", 
                      systemImage: server.isFavorite ? "star.slash" : "star")
            }
            
            Button(action: { viewModel.removeServer(server) }) {
                Label("Remove Server", systemImage: "trash")
                    .foregroundColor(.red)
            }
        }
    }
}

struct QuickConnectCard: View {
    let server: ServerConnectionInfo
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Image(systemName: "server.rack")
                    .foregroundColor(.accentColor)
                    .font(.title2)
                
                Spacer()
                
                if server.isFavorite {
                    Image(systemName: "star.fill")
                        .foregroundColor(.yellow)
                        .font(.caption)
                }
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text(server.name)
                    .font(.headline)
                    .foregroundColor(.primary)
                
                Text(server.host)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Spacer()
            
            Button(action: {
                viewModel.connectToServer(server)
            }) {
                HStack {
                    Image(systemName: "play.fill")
                    Text("Connect")
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .background(Color.accentColor)
                .foregroundColor(.white)
                .cornerRadius(8)
            }
            .buttonStyle(PlainButtonStyle())
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
    }
}



struct ConnectionStatusView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        Button(action: {
            if viewModel.isConnected {
                viewModel.disconnect()
            }
        }) {
            HStack(spacing: 8) {
                Image(systemName: viewModel.connectionState.icon)
                    .foregroundColor(viewModel.connectionState.color)
                
                Text(viewModel.connectionState.rawValue)
                    .font(.caption)
                    .foregroundColor(viewModel.connectionState.color)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(viewModel.connectionState.color.opacity(0.1))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
        .disabled(!viewModel.isConnected)
    }
}
