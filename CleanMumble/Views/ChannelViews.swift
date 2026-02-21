//
//  ChannelViews.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI

struct ChannelListView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Channels")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)
                
                Spacer()
                
                Text("\(viewModel.channels.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top)
                
                Button(action: {}) {
                    Image(systemName: "plus")
                        .font(.caption)
                }
                .padding(.horizontal)
                .padding(.top)
            }
            
            if viewModel.channels.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "folder")
                        .font(.system(size: 40))
                        .foregroundColor(.secondary)
                    Text("No channels available")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                    Text("Channels will appear here when connected to a server")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                List(viewModel.channels) { channel in
                    ChannelRowView(channel: channel)
                        .environmentObject(viewModel)
                }
                .listStyle(PlainListStyle())
            }
        }
    }
}

struct ChannelRowView: View {
    let channel: ChannelInfo
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        HStack {
            Image(systemName: channelIcon(for: channel))
                .foregroundColor(.accentColor)
                .frame(width: 20)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name)
                    .font(.body)
                    .foregroundColor(.primary)
                
                if let description = channel.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            
            Spacer()
            
            if channel.userCount > 0 {
                Text("\(channel.userCount)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.2))
                    .cornerRadius(8)
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .onTapGesture {
            viewModel.joinChannel(channel)
        }
        .contextMenu {
            Button(action: {}) {
                Label("Join Channel", systemImage: "arrow.right.circle")
            }
            
            Button(action: {}) {
                Label("Channel Info", systemImage: "info.circle")
            }
        }
    }
    
    private func channelIcon(for channel: ChannelInfo) -> String {
        if channel.name.lowercased().contains("lobby") {
            return "house"
        } else if channel.name.lowercased().contains("gaming") {
            return "gamecontroller"
        } else if channel.name.lowercased().contains("afk") {
            return "moon.zzz"
        } else if channel.name.lowercased().contains("music") {
            return "music.note"
        } else {
            return "number"
        }
    }
}

struct UserListView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Users")
                    .font(.headline)
                    .padding(.horizontal)
                    .padding(.top)
                
                Spacer()
                
                Text("\(viewModel.users.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.horizontal)
                    .padding(.top)
            }
            
            List(viewModel.users) { user in
                UserRowView(user: user)
                    .environmentObject(viewModel)
            }
            .listStyle(PlainListStyle())
        }
    }
}

struct UserRowView: View {
    let user: UserInfo
    @EnvironmentObject var viewModel: MumbleViewModel
    
    var body: some View {
        HStack {
            // Avatar placeholder
            Circle()
                .fill(Color.accentColor.opacity(0.3))
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(user.name.prefix(1)).uppercased())
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.accentColor)
                )
            
            VStack(alignment: .leading, spacing: 2) {
                Text(user.name)
                    .font(.body)
                    .foregroundColor(user.statusColor)
                
                if let comment = user.comment, !comment.isEmpty {
                    Text(comment)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            
            Spacer()
            
            HStack(spacing: 4) {
                if user.isSpeaking {
                    Image(systemName: "waveform")
                        .foregroundColor(.green)
                        .font(.caption)
                }
                
                if user.isMuted || user.isSelfMuted {
                    Image(systemName: "mic.slash")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                if user.isRecording {
                    Image(systemName: "record.circle")
                        .foregroundColor(.red)
                        .font(.caption)
                }
                
                if user.isDeafened || user.isSelfDeafened {
                    Image(systemName: "speaker.slash")
                        .foregroundColor(.orange)
                        .font(.caption)
                }
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
        .contextMenu {
            Button(action: {}) {
                Label("Send Message", systemImage: "message")
            }
            
            Button(action: {}) {
                Label("User Info", systemImage: "person.circle")
            }
            
            Divider()
            
            Button(action: {}) {
                Label("Mute User", systemImage: "mic.slash")
            }
            
            Button(action: {}) {
                Label("Kick User", systemImage: "person.crop.circle.badge.minus")
            }
        }
    }
}


