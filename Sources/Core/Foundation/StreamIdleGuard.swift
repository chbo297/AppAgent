//
//  StreamIdleGuard.swift
//  AppAgent
//

import Foundation

/// 给一条流套上「相邻两个元素之间的时间上界」。
///
/// ## 为什么需要它
///
/// SSE 流的失败模式不是抛错，而是**静默**：App 被切到后台，iOS 几秒后冻结进程，
/// socket 往往已经被系统或对端撕掉；回到前台时 `URLSession.bytes` 既不再吐字节、
/// 也不抛错，只能等 CFNetwork 的空闲超时（本工程默认 300s）兜底。用户看到的就是
/// 「一直转圈」。执行循环必须自己有一个上界，才能把「静默」翻译成一个可重试的错误。
///
/// ## 为什么用墙钟而不是单调时钟
///
/// 判据是 `Date()` 之差，**挂起时长要算进「没有进展」**：进程被冻结期间连接基本已经死了，
/// 回前台后越早判死越好。墙钟天然把挂起那段计入，所以回到前台的第一次 tick 就能判出来 ——
/// 这也是为什么不需要再挂一个 `willEnterForeground` 观察者去催一脚。
///
/// ## 责任边界
///
/// 「多久没进展算卡死」是执行策略，不是传输细节，所以看门狗在 `LLMExecutor` 这一侧包，
/// `ModelProvider` 只管搬字节。取消沿流向上传播：下游终止 → 中继任务取消 →
/// provider 的 `onTermination` → URLSession 任务取消，不会留下白烧 token 的连接。
enum StreamIdleGuard {

    /// 包一层空闲看门狗。
    ///
    /// - Parameters:
    ///   - upstream: 原始流。被包之后不应再有别处消费它。
    ///   - idleLimit: 相邻两个元素之间允许的最大间隔（秒）。`<= 0` 表示不设上界，原样返回。
    ///   - onStall: 判定卡死时回调，参数是实际空闲时长，用于落日志。
    /// - Returns: 行为与 `upstream` 一致的流；空闲超限时以 `ModelError.streamStalled` 结束。
    static func wrap<Element: Sendable>(
        _ upstream: AsyncThrowingStream<Element, Error>,
        idleLimit: TimeInterval,
        onStall: @escaping @Sendable (TimeInterval) -> Void = { _ in }
    ) -> AsyncThrowingStream<Element, Error> {
        guard idleLimit > 0 else { return upstream }

        let (downstream, continuation) = AsyncThrowingStream<Element, Error>.makePair()
        let state = Locked(wrappedValue: Progress(lastElementAt: Date()))

        let relay = Task {
            do {
                for try await element in upstream {
                    state.mutate { $0.lastElementAt = Date() }
                    continuation.yield(element)
                }
                state.mutate { $0.isFinished = true }
                continuation.finish()
            } catch {
                state.mutate { $0.isFinished = true }
                continuation.finish(throwing: error)
            }
        }

        // 轮询间隔由上界推出，不再多一个旋钮：上界 25s → 1s 一次，测试给 0.3s → 0.075s 一次。
        // 判定延迟因此最多是 idleLimit + tick。
        let tick = max(0.05, min(1.0, idleLimit / 4))
        let watchdog = Task {
            while true {
                try await Task.sleep(nanoseconds: UInt64(tick * 1_000_000_000))
                let snapshot = state.wrappedValue
                // 正常收尾与判定卡死可能同时发生；已收尾就闭嘴，别记一条假的卡死日志。
                guard !snapshot.isFinished else { return }
                let idle = Date().timeIntervalSince(snapshot.lastElementAt)
                guard idle >= idleLimit else { continue }
                onStall(idle)
                // 只 finish，不在这里 cancel：finish 会触发下面的 onTermination，
                // 由它统一收中继任务。反过来先 cancel 的话，中继抛出的 CancellationError
                // 会和这里的 streamStalled 抢着 finish，消费方看到的错误类型就不确定了。
                continuation.finish(throwing: ModelError.streamStalled(idleSeconds: idle))
                return
            }
        }

        continuation.onTermination = { @Sendable _ in
            relay.cancel()
            watchdog.cancel()
        }
        return downstream
    }

    private struct Progress: Sendable {
        var lastElementAt: Date
        var isFinished = false
    }
}
