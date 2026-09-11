// 核心版本断言 —— 1.2.0。放进 app target(或测试二进制)任意一处即可。
//
// 上一版这个文件用 `ChoreographyConfiguration(speechMask:blinkFadesUnderRestOverlay:)`
// 做编译期判别。1.2.0 删掉了 blinkFadesUnderRestOverlay(那条规则是错的,见
// docs/EYELID-CONTRACT.md),所以**请用这一版替换掉旧的那份**,否则它会编译失败。
//
// 现在不再依赖 API 形状这种偶然信号:核心自己带版本号了。

import ExpressionChoreography

/// 编译期证明。`ChoreographyVersion` 是 1.2.0 才有的类型,
/// 对 1.1.0 及更早的核心直接编译失败。
public let linkedChoreographyVersion = ChoreographyVersion.current

/// 运行期证明,测的是三件修复本身而不是版本号字符串。
///
/// - Returns: 三个数。全部符合预期时 `(0, 0.45, 1.0)`。
///   - `pressedStepAtSpeechStart` —— 句子开始时底层表情的单帧跳变。
///     1.1.0/1.2.0 为 0;1.0.0 为 0.272(遮罩占位预算)。
///   - `eyelidTravelAtHalfRest` —— `rest = 0.55` 时眼皮的实际行程。
///     1.2.0 为 0.45;1.1.0 为 **0**(眨眼被静息眼皮完全盖住)。
///   - `eyelidPeakAtHalfRest` —— 同一档的最终闭合峰值,应当到底,即 1.0。
@discardableResult
public func assertChoreographyCoreIsFixed() -> (pressedStepAtSpeechStart: Double,
                                                eyelidTravelAtHalfRest: Double,
                                                eyelidPeakAtHalfRest: Double) {
    // ── 1. 遮罩占位预算(1.1.0 起) ──────────────────────────────────────
    let masking = ChoreographyDirector(
        configuration: ChoreographyConfiguration(speechMask: .speechOwned, ambient: .disabled))
    masking.play(ChoreographySequence(id: "probe.parted", steps: [
        ChoreographyStep(.partedLips, blend: 0.2, hold: 30, label: "probe")]))
    let pressedBase = PoseWeights(pressed: 0.85)
    var time = 0.0
    for _ in 0..<24 {
        _ = masking.update(time: time, input: ChoreographyInput(basePose: pressedBase))
        time += 1.0 / 24
    }
    let quiet = masking.update(time: time, input: ChoreographyInput(basePose: pressedBase)).pose.pressed
    time += 1.0 / 24
    let speaking = masking.update(
        time: time,
        input: ChoreographyInput(basePose: pressedBase, isSpeechActive: true)).pose.pressed

    // ── 2. 眼皮合成(1.2.0) ─────────────────────────────────────────────
    // 渲染器的合成,逐字复制自 PortraitRenderer.blinkAmount(for:)。
    func eyelid(rest: Double, blink: Double) -> Double {
        func unit(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
        return max(unit(rest), unit(blink))
    }
    let eyes = ChoreographyDirector(configuration: ChoreographyConfiguration(ambient: .disabled))
    eyes.play(ChoreographySequence(id: "probe.rest", steps: [
        ChoreographyStep(.resting, intensity: 0.55, blend: 0.2, hold: 30, label: "probe")]))
    var eyeTime = 0.0
    for _ in 0..<24 {
        _ = eyes.update(time: eyeTime, input: ChoreographyInput())
        eyeTime += 1.0 / 24
    }
    var peak = 0.0, restNow = 0.0
    for index in 0..<6 {
        // BlinkClock 自己的形状。
        let e = Double(index) / 24
        let raw = e < 0.055 ? e / 0.055 : (e < 0.125 ? 1 : max(0, 1 - (e - 0.125) / 0.095))
        let out = eyes.update(time: eyeTime, input: ChoreographyInput(baseBlink: raw))
        eyeTime += 1.0 / 24
        restNow = out.pose.rest
        peak = max(peak, eyelid(rest: out.pose.rest, blink: out.blink))
    }
    return (abs(speaking - quiet), peak - restNow, peak)
}
