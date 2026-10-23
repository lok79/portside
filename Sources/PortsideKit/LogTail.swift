import Foundation

/// 日志尾随接缝：PanelViewModel 只认此协议（可注入假实现验证 stop 纪律）。
public protocol LogTailing: AnyObject, Sendable {
    /// 开始跟随（幂等：重复调用无副作用）。
    func start()
    /// 停止跟随：轮询任务终止、文件句柄关闭（幂等；未启动也可调用）。
    func stop()
}

/// 日志尾随器（工单 07，GLOSSARY：日志流）：打开日志文件读末尾 N 行，随后跟随新增。
/// - **轮询而非 FSEvents**（工单口径：保持简单可测）：每 `pollInterval`（默认 0.5s，
///   新写入 <1s 可见）用文件属性比较 size；时钟注入，测试拨虚拟时间不真睡（低资源）。
/// - **增量回调**：只输出完整行（无换行结尾的半行缓冲，补全后成行输出）。
/// - **轮转/截断**：size 比上次记录变小（logrotate/`>` 重定向）→ 关闭重开、重读末尾。
/// - **文件未建**：静默等待（托管服务刚启动落盘文件尚未出现的形态），出现即读。
/// - **stop() 后无残留**：轮询任务取消即退出，句柄在退出路径关闭（测试以 lsof 实证）。
public final class LogTail: LogTailing, @unchecked Sendable {
    /// 回填字节数上限（只读末尾：大文件不全量读，行数再裁到 maxLines）。
    private static let maxBackfillBytes = 262_144

    private let url: URL
    private let clock: PortsideClock
    private let pollInterval: Duration
    private let maxLines: Int
    private let onUpdate: @Sendable (String) -> Void

    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var handle: FileHandle?
    private var byteOffset: UInt64 = 0
    private var pendingPartialLine: String = ""

    /// - Parameters:
    ///   - url: 日志文件路径（LogLocator 的产出）。
    ///   - clock: 时钟（注入；测试用 ManualClock）。
    ///   - pollInterval: stat 轮询间隔（默认 0.5s）。
    ///   - maxLines: 回填末尾行数（spec §6：500）。
    ///   - onUpdate: 行增量回调（完整行，含结尾换行；任意线程触发）。
    public init(
        url: URL,
        clock: PortsideClock = SystemClock(),
        pollInterval: Duration = .milliseconds(500),
        maxLines: Int = 500,
        onUpdate: @escaping @Sendable (String) -> Void
    ) {
        self.url = url
        self.clock = clock
        self.pollInterval = pollInterval
        self.maxLines = maxLines
        self.onUpdate = onUpdate
    }

    public var isFollowing: Bool {
        lock.withLock { task != nil }
    }

    public func start() {
        lock.withLock {
            guard task == nil else { return }
            task = Task { [weak self] in
                await self?.runLoop()
            }
        }
    }

    public func stop() {
        let running: Task<Void, Never>? = lock.withLock {
            defer { task = nil }
            return task
        }
        running?.cancel()
        // 句柄由轮询任务退出路径关闭（cancel 唤醒 sleep → defer close）——
        // 不在这里跨线程 close：FileHandle 并发 close 与读会竞态。
    }

    // MARK: - 轮询循环（单任务内串行，句柄只在此任务线程读写）

    private func runLoop() async {
        defer { closeHandle() }
        while !Task.isCancelled {
            pollOnce()
            do {
                try await clock.sleep(for: pollInterval)
            } catch {
                break   // 取消即退出，不留残余任务（句柄由 defer 关闭）
            }
        }
    }

    private func pollOnce() {
        let attributes = try? FileManager.default.attributesOfItem(atPath: url.path)
        guard let size = attributes?[.size] as? UInt64 else {
            // 文件未建/已被轮走：丢弃半行，句柄关闭，等待重新出现。
            closeHandle()
            byteOffset = 0
            pendingPartialLine = ""
            return
        }
        if handle == nil || size < byteOffset {
            // 首次打开，或截断/轮转（size 变小）→ 重开读末尾。
            reopenAndBackfill(size: size)
            return
        }
        if size > byteOffset, let handle {
            readNewData(from: handle)
        }
    }

    /// 打开文件读末尾 ≤ maxLines 行（大文件只读末尾 maxBackfillBytes 字节）。
    private func reopenAndBackfill(size: UInt64) {
        closeHandle()
        pendingPartialLine = ""
        guard let handle = try? FileHandle(forReadingFrom: url) else {
            byteOffset = 0
            return
        }
        self.handle = handle
        // 偏移先判再减：size 不足上限时直接从 0 读（工单 06 同款下溢教训）。
        let readOffset = size > UInt64(Self.maxBackfillBytes)
            ? size - UInt64(Self.maxBackfillBytes) : 0
        try? handle.seek(toOffset: readOffset)
        let data = handle.readDataToEndOfFile()
        var text = String(decoding: data, as: UTF8.self)
        // 末尾无换行的半行进缓冲，等补全（同跟随路径一致）。
        if let lastNewline = text.lastIndex(of: "\n") {
            pendingPartialLine = String(text[text.index(after: lastNewline)...])
            text = String(text[text.startIndex...lastNewline])
        } else {
            pendingPartialLine = text
            text = ""
        }
        byteOffset = size
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == Substring("") {
            lines.removeLast()   // 结尾换行在 split 后产生的空尾巴段，不是真实行
        }
        let tail = lines.suffix(maxLines).joined(separator: "\n")
        if !tail.isEmpty {
            onUpdate(tail + "\n")
        }
    }

    /// 从上次偏移读新增字节，拆出完整行输出，半行留缓冲。
    private func readNewData(from handle: FileHandle) {
        try? handle.seek(toOffset: byteOffset)
        let data = handle.readDataToEndOfFile()
        guard !data.isEmpty else { return }
        byteOffset += UInt64(data.count)
        let combined = pendingPartialLine + String(decoding: data, as: UTF8.self)
        guard let lastNewline = combined.lastIndex(of: "\n") else {
            pendingPartialLine = combined
            return
        }
        pendingPartialLine = String(combined[combined.index(after: lastNewline)...])
        let complete = String(combined[combined.startIndex...lastNewline])
        onUpdate(complete)
    }

    private func closeHandle() {
        try? handle?.close()
        handle = nil
    }
}
