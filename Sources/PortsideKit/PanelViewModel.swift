import Foundation

/// 面板 ViewModel（工单 04 起，工单 05 扩展定义接线）：把 RefreshScheduler 驱动的
/// CompositeScanner → 识别 → 分区 串成一条 @MainActor 管线（GLOSSARY：面板/扫描器）。
/// - 服务上下线自动反映：每轮 tick 全量重扫重算后发布，无手动刷新按钮（spec 用户故事 1）。
/// - 「隐藏其他」经注入的 KeyValueStore 持久化；隐藏/折叠只影响渲染，模型层数据不丢。
/// - 菜单栏汇总态每轮随扫描重算（GLOSSARY：菜单栏图标；注入 knownDefinitions 可测）。
/// - 服务定义（工单 05）：收编/编辑后从最近一次扫描结果**免扫描重算**（立即反映，
///   不等下一轮 tick）；有定义无匹配实例 → 托管·已停止行（「我的服务」区，带启动动作）；
///   匹配 = 端口 + 规范化启动命令（DefinitionMatcher，工单 08 认领复用）。
/// - 低资源：面板可见才记录活动（活动档 5s），隐藏后退避（空闲档 30s/120s）；
///   UI 不做每秒重算，行内文案只在扫描轮更新。
@MainActor
public final class PanelViewModel: ObservableObject {
    /// 「隐藏其他」的持久化键。
    public static let hideOtherKey = "panel.hideOther"

    // MARK: - 面板状态（UI 唯一读取面）

    /// 全量行（含被隐藏分区的行）——隐藏只影响渲染不丢数据。
    @Published public private(set) var allRows: [PanelRow] = []
    /// 列表顶部明示行：partial 扫描的解释文案 / 扫描失败提示；nil = 正常不显。
    @Published public private(set) var scanNotice: String?
    /// 菜单栏汇总态（MenuBarExtra 图标据此切换）。
    @Published public private(set) var health: MenuBarBadgeState = .normal
    /// 聚合行展开状态（渲染态，默认折叠；不持久化）。
    @Published private var expandedRowIDs: Set<String> = []
    /// 托管动作待确认（工单 06：停止/重启前二次确认，spec §4；nil = 无待确认）。
    @Published public private(set) var pendingConfirmation: ManagedActionConfirmation?
    /// 托管行内状态（工单 06：启动失败错误可见不装死；定义 id → 文案）。
    @Published public private(set) var managedStatusMessages: [String: String] = [:]
    /// 日志流上下文（工单 07）：非 nil = 日志视图激活（同窗切换，形态 A）。
    @Published public private(set) var logContext: LogContext?
    /// 日志流状态（ locating → found/notFound；logText 持增量内容）。
    @Published public private(set) var logStatus: LogStreamStatus = .locating
    /// 日志文本（tail 增量累积，超容量保尾部截断）。
    @Published public private(set) var logText = ""
    /// 「隐藏其他」开关：读经持久层，写穿持久层。
    @Published public var isOtherHidden: Bool {
        didSet { store.set(isOtherHidden, forKey: Self.hideOtherKey) }
    }

    // MARK: - 协作对象

    private let scanner: PortScanner
    private let engine: ServiceIdentificationEngine
    private let resolver: DisplayNameResolver
    private let assigner: SectionAssigner
    private let knownDefinitions: @Sendable () -> [KnownServiceDefinition]
    private let uptimeFetcher: ProcessUptimeFetcher?
    /// 服务定义中枢（工单 05）：已停止定义行来源 + 收编/编辑/动作入口；nil = 无定义形态（工单 04）。
    private let definitions: ServiceDefinitionCenter?
    /// 进程控制接缝（工单 06 实装）：托管动作送达处；nil = 桩（动作不产生效果）。
    private let processController: ProcessController?
    /// 日志定位接缝（工单 07）：发现链入口；nil = 日志视图不可用（动作无效果）。
    private let logLocator: LogLocating?
    /// 日志尾随工厂（工单 07）：可注入假实现验证 stop 纪律。
    private let logTailFactory: LogTailFactory
    private let store: KeyValueStore
    private let refreshMode: RefreshMode
    private let clock: PortsideClock
    private let idleThreshold: Duration
    /// 最近一次成功扫描结果：定义变更时免扫描重算（低资源：改名/收编不触发新一轮 lsof）。
    private var lastScan: ScanResult?
    /// 当前活跃 tail（同一时刻最多一个：新开必先停旧，工单资源安全要求）。
    private var activeTail: LogTailing?
    /// 日志会代号：返回/切换/隐藏即自增，过期发现结果按代号丢弃（防孤儿 tail）。
    private var logGeneration = 0
    /// 日志文本容量上限（低内存：超容量保尾部截断；~200KB 文本对滚动视图足够）。
    private static let logTextCapacity = 200_000
    /// 生产默认尾随工厂：0.5s 轮询（新写入 <1s 可见，工单验收）。
    private static let defaultLogTailFactory: LogTailFactory = { url, onUpdate in
        LogTail(url: url, clock: SystemClock(), onUpdate: onUpdate)
    }
    /// lazy：创建时才捕获 self（初始化完成后），避免 init 两阶段限制。
    private lazy var scheduler = RefreshScheduler(
        mode: refreshMode, clock: clock, idleThreshold: idleThreshold
    ) { [weak self] _ in
        Task { @MainActor [weak self] in
            await self?.refreshOnce()
        }
    }
    /// 在途刷新闸：上一轮没落定就跳过本轮 tick，避免扫描慢时任务堆积（低资源）。
    private var isRefreshing = false
    /// start 幂等闸（调度器自身幂等，这里防初始刷新重复发）。
    private var started = false

    public init(
        scanner: PortScanner,
        engine: ServiceIdentificationEngine,
        resolver: DisplayNameResolver = DisplayNameResolver(),
        assigner: SectionAssigner = SectionAssigner(),
        knownDefinitions: @escaping @Sendable () -> [KnownServiceDefinition] = { [] },
        uptimeFetcher: ProcessUptimeFetcher? = nil,
        definitions: ServiceDefinitionCenter? = nil,
        processController: ProcessController? = nil,
        store: KeyValueStore,
        clock: PortsideClock = SystemClock(),
        refreshMode: RefreshMode = RefreshMode.defaultMode,
        idleThreshold: Duration = .seconds(120),
        logLocator: LogLocating? = nil,
        logTailFactory: LogTailFactory? = nil
    ) {
        self.scanner = scanner
        self.engine = engine
        self.resolver = resolver
        self.assigner = assigner
        self.knownDefinitions = knownDefinitions
        self.uptimeFetcher = uptimeFetcher
        self.definitions = definitions
        self.processController = processController
        self.logLocator = logLocator
        self.logTailFactory = logTailFactory ?? Self.defaultLogTailFactory
        self.store = store
        self.refreshMode = refreshMode
        self.clock = clock
        self.idleThreshold = idleThreshold
        self.isOtherHidden = store.bool(forKey: Self.hideOtherKey)
    }

    /// 生产装配：真实扫描器 + 识别引擎 + ps 运行时长采集 + UserDefaults 偏好 +
    /// 服务定义中枢（JSON 落盘应用容器）+ 进程控制真实现（工单 06）+
    /// 日志管道真实现（工单 07：lsof 发现链 + 落盘目录 + 0.5s 轮询 tail）。
    public static func production() -> PanelViewModel {
        let runner = SystemProcessRunner()
        let definitions = ServiceDefinitionCenter(
            store: DefinitionStore(directory: DefinitionStore.defaultDirectory())
        )
        let processController = ShellProcessController(
            logsDirectory: ShellProcessController.defaultLogsDirectory(),
            runner: runner
        )
        return PanelViewModel(
            scanner: CompositeScanner(runner: runner),
            engine: .defaultEngine(runner: runner),
            resolver: DisplayNameResolver(aliasLookup: { definitions.alias(for: $0) }),
            assigner: SectionAssigner(hasDefinition: { definitions.hasDefinition(for: $0) }),
            knownDefinitions: { definitions.knownDefinitions() },
            uptimeFetcher: ProcessUptimeFetcher(runner: runner),
            definitions: definitions,
            processController: processController,
            store: UserDefaultsStore(),
            logLocator: LogLocator.production(
                managedLogsDirectory: ShellProcessController.defaultLogsDirectory()
            )
        )
    }

    // MARK: - 生命周期

    /// 启动：先立刻刷一次（打开即有数据），再进入调度节拍；重复调用无副作用。
    public func start() {
        guard !started else { return }
        started = true
        Task { [weak self] in
            await self?.refreshOnce()
        }
        scheduler.start()
    }

    public func stop() {
        scheduler.stop()
    }

    /// 面板出现（MenuBarExtra 窗口打开）：记录活动 → 活动档快刷。
    public func panelDidAppear() {
        scheduler.recordActivity()
    }

    /// 面板隐藏：不记录活动 → 空闲退避（低资源：隐藏时不加速刷新）；
    /// 同时停掉日志 tail 并退出日志视图（工单 07：面板隐藏即停，重开回列表）。
    public func panelDidDisappear() {
        closeLog()
    }

    // MARK: - 行查询（渲染用）

    /// 某分区的行（数据层，不受「隐藏其他」影响；渲染层自行判断 isOtherHidden）。
    public func rows(in section: ServiceSectionKind) -> [PanelRow] {
        allRows.filter { $0.section == section }
    }

    /// 聚合行是否展开（默认折叠）。
    public func isExpanded(_ id: String) -> Bool {
        expandedRowIDs.contains(id)
    }

    /// 展开/收起聚合行。
    public func toggleExpanded(_ id: String) {
        if expandedRowIDs.contains(id) {
            expandedRowIDs.remove(id)
        } else {
            expandedRowIDs.insert(id)
        }
    }

    // MARK: - 管线

    /// 一轮完整刷新：扫描 → 识别 → 分区 → 行模型 → 发布。可独立调用（测试/首刷共用）。
    public func refreshOnce() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer { isRefreshing = false }

        let result: ScanResult
        do {
            result = try await scanner.scan()
        } catch {
            // 扫描失败：保留上次数据（不折腾用户），顶部明示（不装死）。
            scanNotice = "扫描失败，显示的是上一次结果：\(String(describing: error))"
            return
        }
        lastScan = result
        await recompute(from: result)
    }

    /// 从既有扫描结果重算整条管线（识别 → 分区 → 行 → 汇总态），不触发新扫描。
    /// 扫描轮与定义变更轮（收编/编辑，工单 05）共用，保证「定义变更 → 面板立即重算」。
    private func recompute(from result: ScanResult) async {
        let identified = await engine.identifyAll(result.services, resolver: resolver)
        let uptimes = await uptimeFetcher?.fetch(pids: identified.compactMap { $0.service.pid }) ?? [:]
        let grouping = assigner.group(identified)

        var rows: [PanelRow] = []
        var matchedDefinitionIDs = Set<String>()
        rows.reserveCapacity(identified.count)
        for section in ServiceSectionKind.allCases {
            let services = grouping[section] ?? []
            if section == .other {
                rows += PanelRowFactory.aggregatedRows(from: services, uptimes: uptimes)
            } else if section == .mine {
                for service in services {
                    // 托管·运行中：匹配到的定义提供托管标记/路径前缀/动作路由 id。
                    let definition = definitions?.matchedDefinition(for: service.service)
                    if let definition {
                        matchedDefinitionIDs.insert(definition.id)
                        // 自动认领（工单 08，adr/0001）：按定义匹配到的运行中实例登记进
                        // 进程控制器（受管外部实例）。首轮扫描即认领（app 打开几秒内列表
                        // 即正确）；登记 O(1) 同步完成不阻塞 UI，重复登记幂等（亲生身份
                        // 保留）；partial 扫描照常按可用数据走——拿不到命令行的实例
                        // 在匹配器处自然落空（宁漏认不误认）。
                        if let pid = service.service.pid {
                            processController?.reclaim(definitionID: definition.id, pid: pid_t(pid))
                        }
                    }
                    rows.append(PanelRowFactory.leafRow(
                        for: service, section: .mine,
                        uptimeText: service.service.pid.flatMap { uptimes[$0] }.map(UptimeText.format),
                        definition: definition
                    ))
                }
            } else {
                rows += services.map { service in
                    PanelRowFactory.leafRow(
                        for: service, section: section,
                        uptimeText: service.service.pid.flatMap { uptimes[$0] }.map(UptimeText.format)
                    )
                }
            }
        }

        // 托管·已停止（工单 05）：有定义无匹配实例 → 「我的服务」区补行（启动按钮），
        // 端口升序、同端口按创建序。运行中的定义不重复出停止行。
        if let definitions {
            let stopped = definitions.all()
                .filter { !matchedDefinitionIDs.contains($0.id) }
                .sorted { ($0.port, $0.createdAt.timeIntervalSince1970) <
                    ($1.port, $1.createdAt.timeIntervalSince1970) }
            rows += stopped.map(PanelRowFactory.stoppedRow)
        }

        allRows = rows
        expandedRowIDs = expandedRowIDs.filter { id in rows.contains { $0.id == id } }
        scanNotice = result.isPartial
            ? (result.partialNotice ?? "清单可能不完整（扫描受限）。")
            : nil
        health = MenuBarBadge.state(
            knownServices: knownDefinitions(),
            listeningPorts: Set(result.services.map(\.port))
        )
    }

    // MARK: - 服务定义（收编/编辑，工单 05）

    /// 收编：生成定义并立即重算面板（不等下一轮扫描）。取消收编 = 不调用本方法，无副作用。
    /// - Returns: 生效后的定义 id（UI 关联用）。
    @discardableResult
    public func adoptService(
        name: String, commandLine: String, port: Int, pathPrefix: String
    ) async -> String? {
        guard let definitions else { return nil }
        let id = definitions.adopt(
            name: name, commandLine: commandLine, port: port, pathPrefix: pathPrefix
        ).id
        await recompute(from: lastScan ?? ScanResult(services: [], source: .lsof))
        return id
    }

    /// 编辑定义（名称即别名、路径前缀）并立即重算面板。
    public func editDefinition(id: String, name: String, pathPrefix: String) async {
        guard let definitions else { return }
        definitions.edit(id: id, name: name, pathPrefix: pathPrefix)
        await recompute(from: lastScan ?? ScanResult(services: [], source: .lsof))
    }

    // MARK: - 托管动作（工单 06：危险动作二次确认 + 启动失败行内状态；日志管道归 07）

    /// 「启动」已停止的托管服务。启动失败写进行内状态（不崩 app），成功清除旧状态。
    public func startService(_ definitionID: String) async {
        guard let definition = definitions?.definition(id: definitionID) else { return }
        do {
            try await processController?.start(definition)
            managedStatusMessages[definitionID] = nil
        } catch {
            managedStatusMessages[definitionID] = (error as? ProcessStartError)?.userMessage
                ?? "启动失败：\(String(describing: error))"
        }
        await refreshOnce()
    }

    /// 停止托管服务（直接执行路径；UI 走 `requestStopService` 确认流）。
    public func stopService(_ definitionID: String) async {
        guard let definition = definitions?.definition(id: definitionID) else { return }
        try? await processController?.stop(definition)
        await refreshOnce()
    }

    /// 重启托管服务（直接执行路径；UI 走 `requestRestartService` 确认流）。
    public func restartService(_ definitionID: String) async {
        guard let definition = definitions?.definition(id: definitionID) else { return }
        try? await processController?.restart(definition)
        await refreshOnce()
    }

    /// 请求停止：只挂起确认（服务名/端口/动作解释），**不杀**——确认后才送达控制器。
    public func requestStopService(_ definitionID: String) {
        guard let definition = definitions?.definition(id: definitionID) else { return }
        pendingConfirmation = ManagedActionConfirmation(
            definitionID: definitionID, kind: .stop,
            serviceName: definition.name, port: definition.port
        )
    }

    /// 请求重启：只挂起确认，**不杀**——确认后才送达控制器。
    public func requestRestartService(_ definitionID: String) {
        guard let definition = definitions?.definition(id: definitionID) else { return }
        pendingConfirmation = ManagedActionConfirmation(
            definitionID: definitionID, kind: .restart,
            serviceName: definition.name, port: definition.port
        )
    }

    /// 确认待执行动作：此刻才把停止/重启送达进程控制器。
    public func confirmPendingManagedAction() async {
        guard let pending = pendingConfirmation else { return }
        pendingConfirmation = nil
        switch pending.kind {
        case .stop: await stopService(pending.definitionID)
        case .restart: await restartService(pending.definitionID)
        }
    }

    /// 取消待确认动作：什么都不发生。
    public func cancelPendingManagedAction() {
        pendingConfirmation = nil
    }

    /// 定义行的行内状态文案（nil = 无）。
    public func statusMessage(forDefinitionID id: String) -> String? {
        managedStatusMessages[id]
    }

    // MARK: - 日志流（工单 07，spec §6：托管与外部统一"发现文件 → tail"）

    /// 点服务行 → 同窗切到日志视图（形态 A）：先停旧 tail（切服务/重复点击），
    /// 再走发现链定位日志文件；命中即启动 tail（回填末尾 500 行 + 跟随），
    /// 未发现则明示文案（不装死）。发现是异步的：返回/切换后过期结果按代号丢弃。
    public func openLog(rowID: String) {
        guard let row = findRow(id: rowID), let logLocator else { return }
        stopActiveTail()
        logGeneration += 1
        let generation = logGeneration
        // 认领实例标记（工单 08）：受管外部实例「输出未接管」——日志发现按
        // 「标准路径有文件则用 → 外部发现链兜底 → 明示」走（未接管形态进 LogContext）。
        let isReclaimed = row.definitionID.map {
            processController?.isReclaimedInstance(definitionID: $0) ?? false
        } ?? false
        let context = LogContext(
            serviceName: row.displayName,
            port: row.primaryPort,
            isManaged: row.isManaged,
            definitionID: row.definitionID,
            pid: row.pid,
            workingDirectory: row.workingDirectory,
            isReclaimed: isReclaimed
        )
        logContext = context
        logText = ""
        logStatus = .locating
        Task { @MainActor [weak self, logLocator] in
            guard let self else { return }
            let availability = await logLocator.locate(context)
            // 用户可能已返回/切换：此刻上下文已变 → 过期结果直接丢弃（防孤儿 tail）。
            guard generation == self.logGeneration, self.logContext == context else { return }
            switch availability {
            case .available(let url):
                let tail = self.logTailFactory(url) { [weak self] chunk in
                    // 增量从轮询任务线程到达：回主 actor 落 published 状态。
                    Task { @MainActor [weak self] in
                        self?.appendLogText(chunk)
                    }
                }
                self.activeTail = tail
                tail.start()
                self.logStatus = .found
            case .notFound:
                // 明示文案按实例形态区分（工单 08：认领实例 = 输出未接管；外部 = 外部启动）。
                self.logStatus = .notFound(
                    context.isReclaimed
                        ? LogLocator.reclaimedLogNotFoundNotice
                        : LogLocator.externalLogNotFoundNotice
                )
            }
        }
    }

    /// 返回列表：停 tail、清日志视图（确认状态机同款纪律：状态与资源一并回收）。
    public func closeLog() {
        logGeneration += 1
        stopActiveTail()
        logContext = nil
        logText = ""
        logStatus = .locating
    }

    /// 日志视图当前是否激活（UI 同窗切换依据）。
    public var isLogViewActive: Bool { logContext != nil }

    private func stopActiveTail() {
        activeTail?.stop()
        activeTail = nil
    }

    /// tail 行增量落地：追加并保尾部截断（超容量丢头部，低内存硬约束）。
    private func appendLogText(_ chunk: String) {
        logText = Self.trimmedLogText(logText + chunk, capacity: Self.logTextCapacity)
    }

    /// 截断规则（纯函数）：超容量时保尾部、截点对齐行首（视图不出现半行开头）。
    static func trimmedLogText(_ text: String, capacity: Int) -> String {
        guard text.count > capacity else { return text }
        var trimmed = String(text.suffix(capacity))
        if let firstNewline = trimmed.firstIndex(of: "\n") {
            trimmed = String(trimmed[trimmed.index(after: firstNewline)...])
        }
        return trimmed
    }

    /// 在行模型（含聚合明细）里按行 id 查找。
    private func findRow(id: String) -> PanelRow? {
        for row in allRows {
            if row.id == id { return row }
            if let child = row.children.first(where: { $0.id == id }) { return child }
        }
        return nil
    }
}

/// 日志流状态（工单 07）：locating = 发现中/等待回填；found = tail 跟随中（logText 有内容）；
/// notFound = 未发现日志文件（附明示文案，UI 明示行，不装死）。
public enum LogStreamStatus: Equatable, Sendable {
    case locating
    case found
    case notFound(String)
}

/// 日志尾随工厂：URL + 增量回调 → tail 实例（可注入假实现验证 stop 纪律）。
public typealias LogTailFactory = @Sendable (
    _ url: URL, _ onUpdate: @escaping @Sendable (String) -> Void
) -> LogTailing

/// 危险动作确认载荷（工单 06，spec §4：停止/重启前显示服务名/端口/解释并二次确认）。
/// 纯数据，UI 据此渲染弹窗；确认/取消走 ViewModel 状态机（可测：确认前不杀、确认后才杀）。
/// Identifiable（id = 定义 id）供 SwiftUI sheet(item:) 使用；同一定义重复请求直接覆盖。
public struct ManagedActionConfirmation: Equatable, Sendable, Identifiable {
    public enum Kind: Equatable, Sendable {
        case stop
        case restart
    }

    public let definitionID: String
    public let kind: Kind
    /// 服务名（= 定义名/别名）。
    public let serviceName: String
    /// 定义的端口。
    public let port: Int

    public var id: String { definitionID }

    /// 动作标题（「停止服务」/「重启服务」）。
    public var actionLabel: String { kind == .stop ? "停止服务" : "重启服务" }

    /// 动作解释（GLOSSARY：进程组——对整组发信号，fork 的子进程一并处理）。
    public var explanation: String {
        switch kind {
        case .stop:
            return "将对「\(serviceName)」（端口 \(port)）的整个进程组发送终止信号，超时未退出则强制结束；它 fork 的子进程一并停止。"
        case .restart:
            return "将先停止「\(serviceName)」（端口 \(port)）的整个进程组（含 fork 的子进程），再按服务定义重新启动。"
        }
    }
}
