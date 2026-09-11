// 核心版本断言。放进 app target(或测试二进制)任意一处即可。
//
// 为什么需要它:ChoreographyBridge.swift 在 1.0.0 和 1.1.0 里**逐字节相同**,
// 而且 1.1.0 的桥接对着 1.0.0 的核心**也能编译通过**。所以"桥接文件与 1.1.0 相同"
// 和"构建通过"都不能证明链接进去的核心是哪一版 —— 三处修复全在核心里。
//
// 下面两样东西各自给出证明:
//   编译期:这一行只有在核心 >= 1.1.0 时才编译得过。
//   运行期:assertChoreographyCoreIsFixed() 在 1.0.0 上会报出 0.272 的跳变。

import ExpressionChoreography

/// 编译期证明。speechMask 与 blinkFadesUnderRestOverlay 这两个参数标签是 1.1.0
/// 才有的:1.0.0 的 ChoreographyConfiguration 没有它们,编译直接失败。
private let choreographyCoreIsAtLeast1_1_0 = ChoreographyConfiguration(
    speechMask: .speechOwned,
    blinkFadesUnderRestOverlay: true
)

/// 运行期证明,并且测的是修复本身而不是版本号。
///
/// 底层是轻抿唇(0.85),叠加层是微张唇;说话开始时遮罩会压住 parted。
/// 1.1.0 把占位预算按**遮罩前**的总量计算,所以 pressed 不动;
/// 1.0.0 按遮罩后的残量计算,权重被还给底层,pressed 在一帧内从 0.578 跳到 0.850。
///
/// - Returns: 实测的单帧跳变。1.1.0 上应为 0;1.0.0 上约 0.272。
@discardableResult
public func assertChoreographyCoreIsFixed() -> Double {
    _ = choreographyCoreIsAtLeast1_1_0
    let director = ChoreographyDirector(
        configuration: ChoreographyConfiguration(speechMask: .speechOwned, ambient: .disabled))
    director.play(ChoreographySequence(
        id: "version.probe",
        steps: [ChoreographyStep(.partedLips, blend: 0.2, hold: 30, label: "probe")]))

    let base = PoseWeights(pressed: 0.85)
    var time = 0.0
    for _ in 0..<24 {
        _ = director.update(time: time, input: ChoreographyInput(basePose: base))
        time += 1.0 / 24
    }
    let quiet = director.update(time: time, input: ChoreographyInput(basePose: base)).pose.pressed
    time += 1.0 / 24
    let speaking = director.update(
        time: time,
        input: ChoreographyInput(basePose: base, isSpeechActive: true)).pose.pressed
    return abs(speaking - quiet)
}
