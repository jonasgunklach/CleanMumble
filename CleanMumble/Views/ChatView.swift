//
//  ChatView.swift
//  CleanMumble
//
//  Created by Jonas Gunklach on 24.09.25.
//

import SwiftUI
import UniformTypeIdentifiers
#if os(macOS)
import AppKit
#else
import UIKit
import PhotosUI
#endif

// MARK: - Chat message model

struct ChatMessage: Identifiable, Codable {
    let id: UUID
    let content: String
    let sender: String
    let timestamp: Date
    let type: MessageType
    /// URL string for a linked image (e.g. from an HTTP src in an <img> tag).
    var imageURL: String?
    /// Raw bytes for an inline data-URI image (decoded from base64).
    var imageData: Data?
    /// Link-preview embeds from the Fancy Mumble server (wire type 133).
    var linkPreviews: [LinkPreviewData]?

    enum MessageType: String, Codable, CaseIterable {
        case text
        case system
        case action
    }
}

// MARK: - Helpers

private func compressIfNeeded(_ data: Data) -> Data {
    guard data.count > 750_000 else { return data }
    #if os(macOS)
    guard let nsImage = NSImage(data: data),
          let tiff = nsImage.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let jpeg = bitmap.representation(using: .jpeg,
                                           properties: [.compressionFactor: NSNumber(value: 0.7)])
    else { return data }
    return jpeg
    #else
    guard let uiImage = UIImage(data: data),
          let jpeg = uiImage.jpegData(compressionQuality: 0.7)
    else { return data }
    return jpeg
    #endif
}

private func loadImageFromURL(_ url: URL) -> Data? {
    guard let raw = try? Data(contentsOf: url) else { return nil }
    return compressIfNeeded(raw)
}

/// Decodes image bytes into a SwiftUI Image, whatever the platform.
private func decodedImage(_ data: Data) -> Image? {
    #if os(macOS)
    return NSImage(data: data).map { Image(nsImage: $0) }
    #else
    return UIImage(data: data).map { Image(uiImage: $0) }
    #endif
}

#if os(macOS)
/// Saves image bytes to ~/Downloads with a timestamped filename.
private func saveImageToDownloads(_ data: Data) {
    let downloads = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first!
    let formatter = DateFormatter()
    formatter.dateFormat = "yyyyMMdd-HHmmss"
    let name = "CleanMumble-\(formatter.string(from: Date())).jpg"
    let dest = downloads.appendingPathComponent(name)
    do {
        try data.write(to: dest)
        NSWorkspace.shared.open(downloads)
    } catch {
        print("[Chat] saveImageToDownloads failed: \(error)")
    }
}
#endif

/// Context-menu item for image bytes: Save to Downloads on macOS, the
/// system share sheet (→ Save Image / Save to Files) on iOS.
@ViewBuilder
private func imageSaveMenuItems(for data: Data) -> some View {
    #if os(macOS)
    Button { saveImageToDownloads(data) } label: {
        Label("Save to Downloads", systemImage: "square.and.arrow.down")
    }
    #else
    if let uiImage = UIImage(data: data) {
        let img = Image(uiImage: uiImage)
        ShareLink(item: img, preview: SharePreview("Image", image: img)) {
            Label("Share…", systemImage: "square.and.arrow.up")
        }
    }
    #endif
}

/// Same, for a remote image URL.
@ViewBuilder
private func imageSaveMenuItems(for url: URL) -> some View {
    #if os(macOS)
    Button {
        Task { if let data = try? Data(contentsOf: url) { saveImageToDownloads(data) } }
    } label: {
        Label("Save to Downloads", systemImage: "square.and.arrow.down")
    }
    #else
    ShareLink(item: url) {
        Label("Share…", systemImage: "square.and.arrow.up")
    }
    #endif
}

// MARK: - Lightbox

struct LightboxItem {
    let messageID: UUID
    let imageData: Data?
    let imageURL: String?
    let sender: String
    let timestamp: Date
}

struct LightboxView: View {
    let items: [LightboxItem]
    @Binding var currentIndex: Int?
    @State private var scale: CGFloat = 1.0
    @State private var keyMonitor: Any? = nil

    private var index: Int {
        guard let i = currentIndex, items.indices.contains(i) else { return 0 }
        return i
    }

    var body: some View {
        ZStack {
            Color.black.opacity(0.78)
                .ignoresSafeArea()
                .onTapGesture { dismiss() }

            VStack(spacing: 0) {
                // Top bar
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(items[index].sender)
                            .font(.headline).foregroundColor(.white)
                        Text(items[index].timestamp, style: .time)
                            .font(.caption).foregroundColor(.white.opacity(0.6))
                    }
                    Spacer()
                    if items.count > 1 {
                        Text("\(index + 1) / \(items.count)")
                            .font(.caption).foregroundColor(.white.opacity(0.7))
                            .padding(.horizontal, 10).padding(.vertical, 4)
                            .background(Color.white.opacity(0.12), in: Capsule())
                    }
                    Spacer()
                    Button { dismiss() } label: {
                        Image(systemName: "xmark.circle.fill")
                            .font(.title2)
                            .symbolRenderingMode(.hierarchical)
                            .foregroundColor(.white)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.horizontal, 20).padding(.vertical, 12)
                .background(.ultraThinMaterial)

                // Main image + arrow overlay
                ZStack {
                    mainImageView(for: items[index])
                        .scaleEffect(scale)
                        .gesture(
                            MagnificationGesture()
                                .onChanged { scale = max(1, $0) }
                                .onEnded { _ in withAnimation(.spring()) { scale = 1 } }
                        )

                    // Swipe to navigate
                    Color.clear
                        .contentShape(Rectangle())
                        .gesture(
                            DragGesture(minimumDistance: 40)
                                .onEnded { v in
                                    if v.translation.width < -40 { next() }
                                    else if v.translation.width > 40 { prev() }
                                }
                        )

                    // Arrow buttons
                    HStack {
                        Button(action: prev) {
                            Image(systemName: "chevron.left.circle.fill")
                                .font(.system(size: 36))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.white).shadow(radius: 6)
                        }
                        .buttonStyle(.plain)
                        .opacity(index > 0 ? 1 : 0)

                        Spacer()

                        Button(action: next) {
                            Image(systemName: "chevron.right.circle.fill")
                                .font(.system(size: 36))
                                .symbolRenderingMode(.hierarchical)
                                .foregroundColor(.white).shadow(radius: 6)
                        }
                        .buttonStyle(.plain)
                        .opacity(index < items.count - 1 ? 1 : 0)
                    }
                    .padding(.horizontal, 24)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Thumbnail strip
                if items.count > 1 {
                    thumbnailStrip
                }
            }
        }
        .onAppear { startKeyMonitor() }
        .onDisappear { stopKeyMonitor() }
    }

    @ViewBuilder
    private func mainImageView(for item: LightboxItem) -> some View {
        if let data = item.imageData, let image = decodedImage(data) {
            image
                .resizable().scaledToFit().padding(40)
                .contextMenu { imageSaveMenuItems(for: data) }
        } else if let urlString = item.imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable().scaledToFit().padding(40)
                        .contextMenu { imageSaveMenuItems(for: url) }
                case .empty:   ProgressView().tint(.white)
                case .failure: Label("Failed to load", systemImage: "exclamationmark.triangle").foregroundColor(.white.opacity(0.6))
                @unknown default: EmptyView()
                }
            }
        }
    }

    @ViewBuilder
    private var thumbnailStrip: some View {
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 6) {
                    ForEach(items.indices, id: \.self) { i in
                        thumbnailCell(for: items[i], isSelected: i == index)
                            .onTapGesture { withAnimation { currentIndex = i; scale = 1 } }
                            .id(i)
                    }
                }
                .padding(.horizontal, 12).padding(.vertical, 8)
            }
            .onChange(of: index) { newIdx in
                withAnimation { proxy.scrollTo(newIdx, anchor: .center) }
            }
        }
        .frame(height: 80)
        .background(.ultraThinMaterial)
    }

    @ViewBuilder
    private func thumbnailCell(for item: LightboxItem, isSelected: Bool) -> some View {
        Group {
            if let data = item.imageData, let image = decodedImage(data) {
                image.resizable().scaledToFill()
            } else if let urlString = item.imageURL, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if case .success(let img) = phase { img.resizable().scaledToFill() }
                    else { Color.white.opacity(0.15) }
                }
            } else {
                Color.white.opacity(0.15)
            }
        }
        .frame(width: 56, height: 56)
        .clipped()
        .cornerRadius(6)
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(isSelected ? Color.accentColor : Color.white.opacity(0.2),
                        lineWidth: isSelected ? 2 : 1)
        )
        .opacity(isSelected ? 1 : 0.55)
        .scaleEffect(isSelected ? 1.05 : 1.0)
        .animation(.spring(response: 0.3), value: isSelected)
    }

    private func dismiss() { withAnimation(.easeInOut(duration: 0.2)) { currentIndex = nil } }
    private func prev()    { guard index > 0               else { return }; withAnimation { currentIndex = index - 1; scale = 1 } }
    private func next()    { guard index < items.count - 1 else { return }; withAnimation { currentIndex = index + 1; scale = 1 } }

    private func startKeyMonitor() {
        #if os(macOS)
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            switch event.keyCode {
            case 123: prev();    return nil  // ←
            case 124: next();    return nil  // →
            case  53: dismiss(); return nil  // Esc
            default:             return event
            }
        }
        #endif
    }

    private func stopKeyMonitor() {
        #if os(macOS)
        if let m = keyMonitor { NSEvent.removeMonitor(m); keyMonitor = nil }
        #endif
    }
}

// MARK: - Paste-aware TextField

#if os(macOS)

/// Wraps NSTextField to intercept Cmd+V when the clipboard holds image data.
struct PasteAwareTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onPasteImage: (Data) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSTextField {
        let tf = PasteTextField()
        tf.placeholderString = placeholder
        tf.isBordered = false
        tf.drawsBackground = false
        tf.focusRingType = .none
        tf.delegate = context.coordinator
        tf.onPasteImage = onPasteImage
        return tf
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        if nsView.stringValue != text { nsView.stringValue = text }
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: PasteAwareTextField
        init(_ parent: PasteAwareTextField) { self.parent = parent }
        func controlTextDidChange(_ obj: Notification) {
            if let tf = obj.object as? NSTextField {
                parent.text = tf.stringValue
            }
        }
        func control(_ control: NSControl, textView: NSTextView,
                     doCommandBy selector: Selector) -> Bool {
            if selector == #selector(NSResponder.insertNewline(_:)) {
                parent.onSubmit()
                return true
            }
            return false
        }
    }
}

/// NSTextField subclass that intercepts paste when clipboard contains an image.
private class PasteTextField: NSTextField {
    var onPasteImage: ((Data) -> Void)?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        // Cmd+V
        if event.modifierFlags.contains(.command),
           event.charactersIgnoringModifiers == "v" {
            if let data = imageDataFromPasteboard() {
                onPasteImage?(data)
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }

    private func imageDataFromPasteboard() -> Data? {
        let pb = NSPasteboard.general
        // 1. File URLs (copy file in Finder)
        if let urls = pb.readObjects(forClasses: [NSURL.self],
                                     options: [.urlReadingFileURLsOnly: true]) as? [URL],
           let fileURL = urls.first(where: { u in
               let ext = u.pathExtension.lowercased()
               return ["png","jpg","jpeg","gif","bmp","tiff","webp"].contains(ext)
           }),
           let data = loadImageFromURL(fileURL) {
            return data
        }
        // 2. Raw image data on the pasteboard (screenshot, drag from browser, etc.)
        if let data = pb.data(forType: .png) ?? pb.data(forType: .tiff) {
            return compressIfNeeded(data)
        }
        // 3. NSImage on pasteboard
        if let nsImage = NSImage(pasteboard: pb),
           let tiff = nsImage.tiffRepresentation,
           let bitmap = NSBitmapImageRep(data: tiff),
           let jpeg = bitmap.representation(using: .jpeg,
                                            properties: [.compressionFactor: NSNumber(value: 0.85)]) {
            return jpeg
        }
        return nil
    }
}

#else

/// iOS counterpart: a plain TextField. Image paste arrives via the system
/// paste menu; a long-press paste of images can be added later if needed.
struct PasteAwareTextField: View {
    @Binding var text: String
    var placeholder: String
    var onSubmit: () -> Void
    var onPasteImage: (Data) -> Void

    var body: some View {
        TextField(placeholder, text: $text)
            .textFieldStyle(.plain)
            .onSubmit(onSubmit)
    }
}

#endif

// MARK: - ChatView

struct ChatView: View {
    @EnvironmentObject var viewModel: MumbleViewModel
    @State private var messageText = ""
    @State private var isDroppingOver = false
    @State private var lightboxCurrentIndex: Int? = nil
    #if !os(macOS)
    @State private var showingPhotoPicker = false
    @State private var photoPickerItem: PhotosPickerItem? = nil
    #endif

    private var allImages: [LightboxItem] {
        viewModel.chatMessages.compactMap { msg in
            guard msg.imageData != nil || msg.imageURL != nil else { return nil }
            return LightboxItem(messageID: msg.id, imageData: msg.imageData,
                                imageURL: msg.imageURL, sender: msg.sender, timestamp: msg.timestamp)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Messages list — also the drop target
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(viewModel.chatMessages) { message in
                            let imgIdx = allImages.firstIndex(where: { $0.messageID == message.id })
                            ChatMessageView(
                                message: message,
                                onImageTap: imgIdx.map { i in { lightboxCurrentIndex = i } }
                            )
                            .id(message.id)
                        }
                    }
                    .padding()
                }
                .overlay(dropOverlay)
                .onDrop(of: [.fileURL, .image, .png, .tiff, .jpeg],
                        isTargeted: $isDroppingOver) { providers in
                    handleDrop(providers)
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
                // Image attach button
                Button(action: showImagePicker) {
                    Image(systemName: "photo.badge.plus")
                        .foregroundColor(.secondary)
                        .font(.title3)
                }
                .buttonStyle(.plain)
                .help("Send an image")

                PasteAwareTextField(
                    text: $messageText,
                    placeholder: inputPlaceholder,
                    onSubmit: sendMessage,
                    onPasteImage: { data in
                        viewModel.sendImageMessage(data)
                    }
                )
                .padding(.horizontal, 12)
                .padding(.vertical, 7)
                .background(.ultraThinMaterial, in: Capsule())
                .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08), lineWidth: 1))

                Button(action: sendMessage) {
                    Image(systemName: "paperplane.fill")
                        .foregroundColor(.accentColor)
                        .font(.title3)
                }
                .disabled(messageText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }
            .padding()
        }
        .background(chatBackground)
        .overlay {
            if lightboxCurrentIndex != nil {
                LightboxView(items: allImages, currentIndex: $lightboxCurrentIndex)
                    .transition(.opacity.animation(.easeInOut(duration: 0.2)))
            }
        }
        #if !os(macOS)
        .photosPicker(isPresented: $showingPhotoPicker,
                      selection: $photoPickerItem,
                      matching: .images)
        .onChange(of: photoPickerItem) { item in
            guard let item else { return }
            photoPickerItem = nil
            Task {
                guard let data = try? await item.loadTransferable(type: Data.self) else { return }
                viewModel.sendImageMessage(compressIfNeeded(data))
            }
        }
        #endif
    }

    private var inputPlaceholder: String {
        #if os(macOS)
        return "Type a message… (⌘V to paste image)"
        #else
        return "Type a message…"
        #endif
    }

    private var chatBackground: Color {
        #if os(macOS)
        return Color(NSColor.textBackgroundColor)
        #else
        return Color(UIColor.systemBackground)
        #endif
    }

    @ViewBuilder
    private var dropOverlay: some View {
        if isDroppingOver {
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.accentColor, lineWidth: 2)
                .background(Color.accentColor.opacity(0.08))
                .overlay(
                    Label("Drop to send image", systemImage: "photo.badge.plus")
                        .font(.title3)
                        .foregroundColor(.accentColor)
                )
                .padding(4)
        }
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        for provider in providers {
            // 1. File URL
            if provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
                provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier) { item, _ in
                    guard let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil),
                          let imgData = loadImageFromURL(url) else { return }
                    DispatchQueue.main.async { viewModel.sendImageMessage(imgData) }
                }
                return true
            }
            // 2. Raw image data
            for uti in [UTType.png.identifier, UTType.tiff.identifier,
                        UTType.jpeg.identifier, UTType.image.identifier] {
                if provider.hasItemConformingToTypeIdentifier(uti) {
                    provider.loadDataRepresentation(forTypeIdentifier: uti) { data, _ in
                        guard let data else { return }
                        let compressed = compressIfNeeded(data)
                        DispatchQueue.main.async { viewModel.sendImageMessage(compressed) }
                    }
                    return true
                }
            }
        }
        return false
    }

    private func sendMessage() {
        let trimmed = messageText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        viewModel.sendTextMessage(trimmed)
        messageText = ""
    }

    private func showImagePicker() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.jpeg, .png, .gif, .bmp, .tiff, .webP]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.begin { response in
            guard response == .OK, let url = panel.url else { return }
            guard let imageData = loadImageFromURL(url) else { return }
            DispatchQueue.main.async { viewModel.sendImageMessage(imageData) }
        }
        #else
        showingPhotoPicker = true
        #endif
    }
}

// MARK: - ChatMessageView

struct ChatMessageView: View {
    let message: ChatMessage
    var onImageTap: (() -> Void)? = nil

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

                // Plain text (with clickable links)
                if !message.content.isEmpty {
                    Text(linkedContent)
                        .font(.body)
                        .foregroundColor(.primary)
                        .textSelection(.enabled)
                }

                // Inline image
                inlineImageView

                // Link-preview cards
                if let previews = message.linkPreviews, !previews.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        ForEach(previews.indices, id: \.self) { i in
                            LinkPreviewCard(preview: previews[i])
                        }
                    }
                    .padding(.top, 2)
                }
            }

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(backgroundColor)
        .cornerRadius(8)
    }

    // Build an AttributedString that makes URLs tappable.
    private var linkedContent: AttributedString {
        var result = AttributedString(message.content)
        guard let detector = try? NSDataDetector(
            types: NSTextCheckingResult.CheckingType.link.rawValue) else { return result }
        let nsText = message.content
        let range = NSRange(nsText.startIndex..., in: nsText)
        for match in detector.matches(in: nsText, range: range) {
            guard let url = match.url,
                  let swiftRange = Range(match.range, in: nsText),
                  let attrRange = Range(swiftRange, in: result) else { continue }
            result[attrRange].link = url
            result[attrRange].foregroundColor = Color.accentColor
            result[attrRange].underlineStyle = .single
        }
        return result
    }

    @ViewBuilder
    private var inlineImageView: some View {
        if let data = message.imageData, let image = decodedImage(data) {
            image
                .resizable()
                .scaledToFit()
                .frame(maxWidth: 300)
                .cornerRadius(8)
                .padding(.top, 2)
                .onTapGesture { onImageTap?() }
                .contextMenu { imageSaveMenuItems(for: data) }
        } else if let urlString = message.imageURL, let url = URL(string: urlString) {
            AsyncImage(url: url) { phase in
                switch phase {
                case .success(let img):
                    img.resizable()
                        .scaledToFit()
                        .frame(maxWidth: 300)
                        .cornerRadius(8)
                        .onTapGesture { onImageTap?() }
                        .contextMenu { imageSaveMenuItems(for: url) }
                case .failure: EmptyView()
                case .empty:   ProgressView().frame(width: 100, height: 60)
                @unknown default: EmptyView()
                }
            }
            .padding(.top, 2)
        }
    }

    private var avatarColor: Color {
        switch message.type {
        case .text:   return Color.accentColor
        case .system: return Color.orange
        case .action: return Color.purple
        }
    }

    private var senderColor: Color {
        switch message.type {
        case .text:   return .primary
        case .system: return .orange
        case .action: return .purple
        }
    }

    private var backgroundColor: Color {
        switch message.type {
        case .text:   return Color.clear
        case .system: return Color.orange.opacity(0.1)
        case .action: return Color.purple.opacity(0.1)
        }
    }
}

// MARK: - Link Preview Card

struct LinkPreviewCard: View {
    let preview: LinkPreviewData
    @Environment(\.openURL) private var openURL

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Thumbnail
            if let thumbData = preview.thumbnailData, let image = decodedImage(thumbData) {
                image
                    .resizable()
                    .scaledToFill()
                    .frame(maxWidth: .infinity, maxHeight: 120)
                    .clipped()
            }

            VStack(alignment: .leading, spacing: 3) {
                if let siteName = preview.siteName {
                    Text(siteName)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
                if let title = preview.title {
                    Text(title)
                        .font(.caption)
                        .fontWeight(.semibold)
                        .lineLimit(2)
                }
                if let desc = preview.description {
                    Text(desc)
                        .font(.caption2)
                        .foregroundColor(.secondary)
                        .lineLimit(2)
                }
            }
            .padding(8)
        }
        .frame(maxWidth: 280)
        .background(cardBackground)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(accentBorderColor, lineWidth: 2)
        )
        .onTapGesture {
            if let url = URL(string: preview.url) {
                openURL(url)
            }
        }
    }

    private var cardBackground: Color {
        #if os(macOS)
        return Color(NSColor.controlBackgroundColor)
        #else
        return Color(UIColor.secondarySystemBackground)
        #endif
    }

    private var accentBorderColor: Color {
        guard let packed = preview.accentColor, packed != 0 else {
            return Color.secondary.opacity(0.3)
        }
        let r = Double((packed >> 16) & 0xFF) / 255.0
        let g = Double((packed >>  8) & 0xFF) / 255.0
        let b = Double( packed        & 0xFF) / 255.0
        return Color(red: r, green: g, blue: b).opacity(0.6)
    }
}

