//
//  CleanMumbleTests.swift
//  CleanMumbleTests
//
//  Integration test against magical.rocks:64738
//

import XCTest
import Combine
@testable import CleanMumble

@MainActor
final class MumbleIntegrationTests: XCTestCase {

    private var client: RealMumbleClient!
    private var cancellables = Set<AnyCancellable>()

    override func setUp() async throws {
        client = RealMumbleClient()
    }

    override func tearDown() async throws {
        client.disconnect()
        cancellables.removeAll()
    }

    // ── 1. Connect and reach ServerSync ───────────────────────────────────────

    func test_01_ConnectsToServer() async throws {
        let expectation = XCTestExpectation(description: "Server sends ServerSync → connectionState = .connected")

        client.$connectionState
            .filter { $0 == .connected }
            .first()
            .sink { _ in expectation.fulfill() }
            .store(in: &cancellables)

        client.connect(to: "magical.rocks", port: 64738, username: "FanciestTest")

        await fulfillment(of: [expectation], timeout: 10)

        XCTAssertEqual(client.connectionState, .connected)
        XCTAssertTrue(client.isConnected)
        XCTAssertNotNil(client.serverInfo)
        print("✅ Connected. SessionId=\(client.sessionId)")
        print("   Server info: \(client.serverInfo.map { "\($0.name), welcome: \($0.welcomeText.prefix(80))" } ?? "nil")")
    }

    // ── 2. Receive channel list ────────────────────────────────────────────────

    func test_02_ReceivesChannels() async throws {
        let connExp = XCTestExpectation(description: "Connected")
        let chanExp = XCTestExpectation(description: "At least one channel received")

        client.$connectionState.filter { $0 == .connected }.first()
            .sink { _ in connExp.fulfill() }
            .store(in: &cancellables)

        client.$channels.filter { !$0.isEmpty }.first()
            .sink { channels in
                print("📋 Channels received (\(channels.count)):")
                for ch in channels { print("   [\(ch.channelId)] \(ch.name) parent=\(ch.parentChannelId.map(String.init) ?? "root")") }
                chanExp.fulfill()
            }
            .store(in: &cancellables)

        client.connect(to: "magical.rocks", port: 64738, username: "FanciestTest")

        await fulfillment(of: [connExp, chanExp], timeout: 12)

        XCTAssertFalse(client.channels.isEmpty, "Expected at least one channel")
        print("✅ Got \(client.channels.count) channel(s)")
    }

    // ── 3. Receive user list ───────────────────────────────────────────────────

    func test_03_ReceivesUsers() async throws {
        let connExp = XCTestExpectation(description: "Connected")
        let userExp = XCTestExpectation(description: "At least one user received")

        client.$connectionState.filter { $0 == .connected }.first()
            .sink { _ in connExp.fulfill() }
            .store(in: &cancellables)

        client.$users.filter { !$0.isEmpty }.first()
            .sink { users in
                print("👥 Users received (\(users.count)):")
                for u in users { print("   [\(u.userId)] \(u.name) channel=\(u.currentChannelId.map(String.init) ?? "?")") }
                userExp.fulfill()
            }
            .store(in: &cancellables)

        client.connect(to: "magical.rocks", port: 64738, username: "FanciestTest")

        await fulfillment(of: [connExp, userExp], timeout: 12)

        XCTAssertFalse(client.users.isEmpty, "Expected at least one user (us)")
        print("✅ Got \(client.users.count) user(s)")
    }

    // ── 4. Send a chat message ────────────────────────────────────────────────

    func test_04_SendChatMessage() async throws {
        let connExp = XCTestExpectation(description: "Connected")

        client.$connectionState.filter { $0 == .connected }.first()
            .sink { _ in connExp.fulfill() }
            .store(in: &cancellables)

        client.connect(to: "magical.rocks", port: 64738, username: "FanciestTest")

        await fulfillment(of: [connExp], timeout: 10)
        XCTAssertTrue(client.isConnected)

        // Send a message — local echo should appear immediately in chatMessages
        let before = client.chatMessages.count
        client.sendTextMessage("Hello from CleanMumble integration test 🎙️")
        XCTAssertEqual(client.chatMessages.count, before + 1, "Local echo should be appended")
        print("✅ Message sent, chatMessages.count = \(client.chatMessages.count)")
    }

    // ── 5. Full state dump after 5 seconds ────────────────────────────────────

    func test_05_FullStateDump() async throws {
        let connExp = XCTestExpectation(description: "Connected")

        client.$connectionState.filter { $0 == .connected }.first()
            .sink { _ in connExp.fulfill() }
            .store(in: &cancellables)

        client.connect(to: "magical.rocks", port: 64738, username: "FanciestTest")

        await fulfillment(of: [connExp], timeout: 10)

        // Wait a bit for the full burst of ChannelState / UserState messages to arrive
        try await Task.sleep(nanoseconds: 3_000_000_000)

        print("\n══ Full state after 3s ══════════════════════════")
        print("connectionState : \(client.connectionState)")
        print("sessionId       : \(client.sessionId)")
        print("channels (\(client.channels.count)):")
        for ch in client.channels.sorted(by: { $0.channelId < $1.channelId }) {
            print("  [\(ch.channelId)] \(ch.name)")
        }
        print("users (\(client.users.count)):")
        for u in client.users {
            print("  [\(u.userId)] \(u.name)  ch=\(u.currentChannelId.map(String.init) ?? "?")  muted=\(u.isMuted)  deaf=\(u.isDeafened)")
        }
        print("chat messages   : \(client.chatMessages.count)")
        print("════════════════════════════════════════════════\n")

        XCTAssertEqual(client.connectionState, .connected)
    }
}
