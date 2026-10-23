import XCTest
@testable import PortsideKit

/// 工单 09：刷新三档设置入口——三选一、持久化、切换即时生效。
/// 独立事实来源：spec §1（三档可配、Balanced 默认）+ RefreshScheduler.setMode 契约
/// （对在途轮不生效，下一轮起用新档）。UI 只装配，判定全部在模型层。
@MainActor
final class RefreshModeSettingTests: XCTestCase {
    private func makeModel(
        store: KeyValueStore, clock: PortsideClock = SystemClock(),
        scanner: PortScanner
    ) -> PanelViewModel {
        PanelViewModel(
            scanner: scanner,
            engine: .defaultEngine(runner: FakeProcessRunner()),
            store: store,
            clock: clock
        )
    }

    /// 有界轮询（与 PanelViewModelTests 同款纪律）：VM 的刷新在主 actor 异步落定。
    private func waitUntil(
        timeout: TimeInterval = 5, what: String, _ condition: () -> Bool
    ) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        if condition() { return true }
        print("⚠️ [RefreshModeSettingTests] 等待超时(\(timeout)s)：\(what)")
        return false
    }

    // MARK: - 持久化：读经持久层恢复，写穿持久层

    func test缺省档位Balanced且未写持久层() {
        let store = InMemoryKeyValueStore()
        let model = makeModel(store: store, scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]))

        XCTAssertEqual(model.refreshMode, .balanced, "spec §1：Balanced 默认")
        XCTAssertNil(store.string(forKey: PanelViewModel.refreshModeKey), "用户没动过设置：持久层不落偏好")
    }

    func test切档写持久层重开app恢复上次档位() {
        let store = InMemoryKeyValueStore()
        let model = makeModel(store: store, scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]))

        model.setRefreshMode(.lowResource)
        XCTAssertEqual(
            store.string(forKey: PanelViewModel.refreshModeKey),
            RefreshMode.lowResource.rawValue,
            "切档写穿持久层"
        )
        XCTAssertEqual(model.refreshMode, .lowResource)

        // 重开 app：新模型从同一持久层恢复（工单验收「持久化」）。
        let reopened = makeModel(store: store, scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]))
        XCTAssertEqual(reopened.refreshMode, .lowResource, "重开后恢复上次档位")
    }

    func test持久层损坏值回落默认档不崩() {
        let store = InMemoryKeyValueStore()
        store.set("不认识的档位", forKey: PanelViewModel.refreshModeKey)

        let model = makeModel(store: store, scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]))

        XCTAssertEqual(model.refreshMode, .balanced, "识别不了的存档值回落默认档（不猜、不崩）")
    }

    func test切回的档位往返无损() {
        let store = InMemoryKeyValueStore()
        let model = makeModel(store: store, scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]))

        model.setRefreshMode(.realtime)
        model.setRefreshMode(.lowResource)
        model.setRefreshMode(.balanced)

        XCTAssertEqual(model.refreshMode, .balanced)
        let reopened = makeModel(store: store, scanner: FakeScanner([.success(ScanResult(services: [], source: .lsof))]))
        XCTAssertEqual(reopened.refreshMode, .balanced, "三档随意切换，最后一次为准")
    }

    // MARK: - 即时生效：调度器下一轮起用新档间隔（对在途轮不生效是调度器既有契约）

    /// 虚拟时钟全驱：Balanced 活动 5s 走两轮 → 切 Low Resource → 在途轮仍 5s（t=10），
    /// 之后活动档 30s（t=15~35 无 tick，t=40 才有）——「切换即时生效」的可观测口径。
    func test切低资源档下一轮起用新间隔() async throws {
        let clock = ManualClock()
        let scanner = FakeScanner([.success(ScanResult(services: [], source: .lsof))])
        let model = makeModel(store: InMemoryKeyValueStore(), clock: clock, scanner: scanner)

        model.start()
        addTeardownBlock { model.stop() }
        _ = await waitUntil(what: "首刷落定") { scanner.callCount >= 1 }
        try await clock.waitForSleepRegistration()

        clock.advance(to: .seconds(5))
        _ = await waitUntil(what: "t=5 的 tick（Balanced 活动档）") { scanner.callCount >= 2 }
        try await clock.waitForSleepRegistration()

        model.setRefreshMode(.lowResource)

        // 在途轮（已按旧档挂上 5s）照常触发。
        clock.advance(to: .seconds(10))
        _ = await waitUntil(what: "t=10 的在途 tick") { scanner.callCount >= 3 }
        try await clock.waitForSleepRegistration()

        // Low Resource 活动档 30s：中间不应有任何 tick。
        clock.advance(to: .seconds(35))
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertEqual(scanner.callCount, 3, "低资源档活动期 30s：t=15~35 不该有新扫描")

        clock.advance(to: .seconds(40))
        _ = await waitUntil(what: "t=40 的 tick（新档 30s 间隔）") { scanner.callCount >= 4 }
        model.stop()
    }
}

/// 工单 09：KeyValueStore 的字符串存取（刷新档位持久化的承载）。
final class KeyValueStoreStringTests: XCTestCase {
    func testUserDefaultsStore字符串读写与删除() throws {
        let suite = "portside.tests.\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }
        let store = UserDefaultsStore(defaults: defaults)

        XCTAssertNil(store.string(forKey: "k"), "未写入时缺省 nil")
        store.set("lowResource", forKey: "k")
        XCTAssertEqual(store.string(forKey: "k"), "lowResource")
        store.set(nil, forKey: "k")
        XCTAssertNil(store.string(forKey: "k"), "写 nil = 删除该键")
    }

    func testInMemoryStore字符串读写与删除() {
        let store = InMemoryKeyValueStore()

        XCTAssertNil(store.string(forKey: "k"))
        store.set("realtime", forKey: "k")
        XCTAssertEqual(store.string(forKey: "k"), "realtime")
        store.set(nil, forKey: "k")
        XCTAssertNil(store.string(forKey: "k"))
    }
}
