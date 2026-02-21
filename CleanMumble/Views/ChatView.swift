//
//  ChatView.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI

struct ChatView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    @State private var messageText = ""
    
    var body: some View {
        VStack(spacing: 0) {
            // Messages list
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.chatMessages) { message in
                            ChatMessageView(message: message)
                                .id(message.id)
                        }
                    }
                    .padding()
                }
                .onAppear {
                    if let lastMessage = viewModel.chatMessages.last {
                        proxy.scrollTo(lastMessage.id, anchor: .bottom)
                    }
                }
                .onChange(of: viewModel.chatMessages.count) { _ in
                    if let lastMessage = viewModel.chatMessages.last {
                        withAnimation(.easeInOut(duration: 0.3)) {
                            proxy.scrollTo(lastMessage.id, anchor: .bottom)
                        }
                    }
                }
            }
            
            Divider()
            
            // Message input
            HStack(spacing: 12) {
                TextField("Type a message...", text: $messageText)
                    .textFieldStyle(RoundedBorderTextFieldStyle())
                    .onSubmit {
                        sendMessage()
                    }
                
                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .background(Color(NSColor.textBackgroundColor))
    }
    
    private func sendMessage() {
        let trimmedMessage = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedMessage.isEmpty else { return }
        
        viewModel.sendTextMessage(trimmedMessage)
        messageText = ""
    }
}

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let content: String
    let sender: String
    let timestamp: Date
    let type: MessageType
    
    enum MessageType: String, Codable, CaseIterable {
        case text
        case system
        case action
    }
}

struct ChatMessageView: View {
    let message: ChatMessage
    
    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            // Avatar
            Circle()
                .fill(avatarColor)
                .frame(width: 32, height: 32)
                .overlay(
                    Text(String(message.sender.prefix(1)).uppercased())
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(.white)
                )
            
            VStack(alignment: .leading, spacing: 4) {
                // Sender name and timestamp
                HStack {
                    Text(message.sender)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .foregroundColor(senderColor)
                    
                    Spacer()
                    
                    Text(message.timestamp, style: .time)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                
                // Message content
                Text(message.content)
                    .font(.body)
                    .foregroundColor(.primary)
                    .textSelection(.enabled)
            }
            
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .cornerRadius(8)
    }
    
    private var avatarColor: Color {
        switch message.type {
        case .text:
            return Color.accentColor
        case .system:
            return Color.orange
        case .action:
            return Color.purple
        }
    }
    
    private var senderColor: Color {
        switch message.type {
        case .text:
            return .primary
        case .system:
            return .orange
        case .action:
            return .purple
        }
    }
    
    private var backgroundColor: Color {
        switch message.type {
        case .text:
            return Color.clear
        case .system:
            return Color.orange.opacity(0.1)
        case .action:
            return Color.purple.opacity(0.1)
        }
    }
}
