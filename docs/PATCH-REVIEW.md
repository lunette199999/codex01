# 本地接入补丁复核 · 20260911

对象:`动作编排-本地接入补丁-给网页版复核-20260911`,基线 0.3.5。
按 `docs/ACCEPTANCE.md` 的九项逐条看,外加本包自己提出的几个问题。

**结论:接线本身九项全对,没有发现需要返工的接入错误。**
但有一件事必须先解决,否则那 12 项验收证明不了它想证明的东西。

---

## 零、先说最要紧的:12 项验收无法区分核心是 1.0.0 还是 1.1.0

三处修复(遮罩占位预算、统一 speechMask、连续眨眼衰减)**全部在核心里**，
`ChoreographyBridge.swift` 一个字都没改。我在本仓库实测:

| 检查 | 结果 |
|---|---|
| 本包 `module/ChoreographyBridge.swift` vs 1.1.0 | **逐字节相同**(你们已比对过,我复核确认) |
| 1.0.0 与 1.1.0 的 `ChoreographyBridge.swift` | **也逐字节相同** —— `git diff e0e5059 db26e2c` 空 |
| 1.1.0 的桥接对着 **1.0.0 的核心** | **编译干净通过** |

所以"桥接文件对得上"和"`swift build -c release` 通过"这两件事，
对核心版本**都不构成证据**。而 `00_接入说明.md` 和 `scripts/apply.py` 的用法都写着
`ExpressionChoreography-1.0.0 解包目录`。

更要紧的是 12 项验收**也测不出差别**。它们一共只播四条序列 ——
`speakingSmile`、`softSmileGreeting`、`warmSmile`、`briefEyeRest` ——
其中**没有一条的叠加层含 `parted` 或 `pressed`**。遮罩只压 `parted`；
叠加层里没有 `parted`,遮罩就没有东西可压,占位预算算法的差别不会显现。
我用两个版本的核心实测同一段输入:

```
底层 pressedLips(0.85)+ 微张唇叠加层,说话开始的那一帧:
  核心 1.0.0   pressed 0.5780 -> 0.8500   单帧跳变 0.2720
  核心 1.1.0   pressed 0.5780 -> 0.5780   单帧跳变 0.0000
```

`max_smile_plus_pressed: 0.898` 这个数两版完全一致(= 0.85 × 0.68 + 0.32)，
所以它也不能用来反推版本。

### 给的解法(三件,都很短)

1. **`integrations/local-patch-review/CoreVersionAssertion.swift`** —— 丢进 app target 即可。
   - 编译期:`ChoreographyConfiguration(speechMask:blinkFadesUnderRestOverlay:)`
     这两个参数标签是 1.1.0 才有的。**实测:对着 1.0.0 的核心直接编译失败**，
     对着 1.1.0 通过。这是一条正向的构建期证明。
   - 运行期:`assertChoreographyCoreIsFixed()` 返回上面那个单帧跳变。
     1.1.0 上是 `0.0000`,1.0.0 上是 `0.2720`。测的是修复本身,不是版本号字符串。
2. **`integrations/local-patch-review/apply-version-guard.patch`** —— 给 `apply.py` 加一道闸门，
   核心里缺 `speechMask` / `blinkFadesUnderRestOverlay` 就直接拒绝,并把实际复制进去的
   15 个文件的合并 sha256 打出来。实测 1.0.0 被拒、1.1.0 通过。
3. **`integrations/local-patch-review/core-sha256.txt`** —— 1.1.0 十五个核心文件的逐个 sha256。
   `shasum -a 256 Sources/ExpressionChoreography/*.swift` 一比即知。

### 还有第三处版本可能分叉

`scripts/build-test.sh` 用 `-I "$LIB" -L "$LIB" -lExpressionChoreography` 链接一个
**预先单独构建**的模块,而 `swift build -c release` 给 app 构建的是
`Sources/ExpressionChoreography` 里的那份。两者来源不同,原则上可以是两个版本 ——
也就是说 12 项验收测到的核心,未必是 app 实际跑的那个核心。
最省事的做法:在 `ChoreoIT.main()` 开头打印一次 `assertChoreographyCoreIsFixed()`，
让每次验收报告自己带上核心指纹。

**在这三件做完并重跑之前,这 12 项结果只能表述为"在某一版核心上通过"，
不能表述为"1.1.0 已在 macOS 验收"。**

---

## 一、九项逐条

| # | 复核项 | 结论 | 代码证据 |
|---|---|---|---|
| 1 | `update` 在 `expressionTransition.sample` 之后、`restMouthReturn` 之前 | **✓** | `DesktopController.swift.patch` (b) 段:`sample(at:)` → `choreography.update(...)` → `expressionPose = choreographyFrame.expressionPose` → `expressionPose.parted *= restMouthReturn.amount(...)`,顺序正确 |
| 2 | `RestMouthReturn` 每帧只应用一次,且作用在合成后的姿态 | **✓** | 整个 `renderFrame` 里 `restMouthReturn.amount` 只出现一次,且在 `expressionPose` 已被叠加层覆写之后 |
| 3 | 眨眼值提取一次,不重复调用 | **✓** | `let baseBlink = idle ? blink.value(at: elapsed) : 0`，`MotionFrame` 改用 `choreographyFrame.blink`；`blink.value(at:)` 全帧只此一处 |
| 4 | `blink.trigger(at:)` 在 `blink.value(at:)` 之后 | **✓** | (c) 段在 (a) 段之后,请求落在下一帧 |
| 5 | `mouth` / `mouthWide` 仍来自 `openness` / `wideness` | **✓** | `MotionFrame` 构造里这两项一字未改;补丁没有触碰 `openness`、`wideness`、`mouthTimeline`、`voiceFollower`、`demoStart` |
| 6 | `needsContinuousUpdates` 是 `||` 追加；`timerConditionChanged` 送达 `updateTimer()` | **✓** | `updateTimer` 的 `needed` 末尾追加一项,原有六项一个没动;(d) 段把它并进已有的那次 `updateTimer()` 判断 |
| 7 | 生命周期完整 | **✓ 六处齐全,但 `reduced` 未接** | `show`/`hide`/`windowWillClose`/`willSleep`/`didWake`/`toggleIdle` 全部接上;缺的一项见第二节 |
| 8 | `DesktopController` 其余部分未动 | **✓** | 我把补丁打在 `host-0.3.5/DesktopController.swift` 上，`patch -p1` 干净通过;逐行比对只有接入点、生命周期、新增的 `playSequence`/`play`/`stopSequences`/菜单项。语音链路、`peakMouth`/`peakWide`/`minimumWide`、渲染调用、`applyRelight` 均未改 |
| 9 | 没有引入第二个表情状态源 | **✓** | `playSequence` 与 `play` 都不碰 `expression`；`setExpression` 仍是唯一入口。用例 1 也从行为上确认了(`selected_expression_after: natural`,只被 `setExpression` 改过) |

另外我**复核了一条你们自己声明的前提**并确认成立:
`host-0.3.5/` 的 `Motion.swift`、`DesktopController.swift`、`MouthTimeline.swift`
与本模块 `reference/` 里的 0.3.4 快照**逐字节相同**。这正好消掉
`docs/ACCEPTANCE.md` 里列的第一条 macOS 风险("如果 Motion.swift 已经分叉,桥接就会在这里编译失败")。

### 顺带记下的三个小点(都不是缺陷)

* `renderFrame(forced:)`:即使 `forced` 有值,编排仍会推进一帧、并可能消耗掉一次
  眨眼请求,而那一帧的姿态被丢弃。0.3.5 里没有任何调用方传 `forced`,你们的测试也没有，
  所以现在无影响。若将来要用,建议 `forced != nil` 时跳过 `choreography.update`。
* `@objc func playSequence(_:) -> Bool`:target-action 会忽略返回值,运行时没问题，
  只是不常见。看得出是为了让测试能拿到 `accepted`。
* `00_接入说明.md` 第四节引用的 `preview/choreography-live.gif` 与
  `preview/choreography-trace.png` **不在本包里**。审美验收要看的就是这个,补一下。

---

## 二、`reduced` 未接 —— 最小改法

现状:启动同步与 `toggleIdle` 都是 `choreography.setIdleEnabled(idle)`，
没有 `&& !reduced`。而同一个 `renderFrame` 里,头发和身体位移都已经被
`reduced` 关掉了(`idle && hairEnabled && !reduced`、`idle && !reduced ? 1 : 0`)。
序列也是动态效果,应当跟它们一起关。

补丁在 **`integrations/local-patch-review/reduce-motion.patch`**,净 +19 行，
一个辅助函数 + 三处调用,已在 `host-0.3.5 + 你们的补丁` 上验证可干净应用。

```swift
private var choreographyIdle: Bool?          // nil ⇒ 第一次同步一定会真的发生

private func syncChoreographyIdle(reduced: Bool) {
    let enabled = idle && !reduced
    guard choreographyIdle != enabled else { return }
    choreographyIdle = enabled
    choreography.setIdleEnabled(enabled)
}
```

三处调用:`init`(替换原来的 `setIdleEnabled(idle)`)、`toggleIdle`、
以及 `renderFrame` 里 `let reduced = ...` 之后那一行。

三条设计约束都对上了,而且是**实测**的,不是推断:

* **运行中改系统偏好** —— 复用 `renderFrame` 已经读到的 `reduced`,不多读一次，
  也不需要额外的通知观察者:看得见动的时候一定在渲染,所以一定会被采到。
* **恢复时不补播** —— `setIdleEnabled(true)` 内部是从当前时刻重新 arm
  (`firstDelay` 7~15 秒),不是补上关掉期间欠的次数。实测:待机开着 90 秒起了 4 次，
  关掉 300 秒起了 **0** 次,重新打开后第一次在 **9.88 秒**,不是 0 秒。
  本仓库新增测试 `testReEnablingIdleAfterALongPauseDoesNotFireABacklog` 固化这一点。
* **手动表情操作保留** —— `setIdleEnabled` 只关**自排**的待机行为。
  正在跑的显式序列不受影响，`setExpression` 更是一个字都不碰。
  实测:关掉待机后播一条显式序列,叠加层照样走到 0.32。

一个**产品决定**留给你们,我没有替你们做:reduceMotion 打开时，
**显式**播放的序列要不要也一并缩短或跳过?上面的改法是"不"，
理由是用户主动点的那一下不属于"自然待机动作"。如果无障碍口径要求更严，
就在 `playSequence` 里加一道判断,那是另一回事。

---

## 三、1.1.0 三处修复能否落到真实接线上

**能,但目前还没有被证明已经落上** —— 因为第零节的版本问题。
逐条说修复依赖接线的哪一点,以及你们的接线是否满足:

| 修复 | 依赖的接线条件 | 接线是否满足 | 是否已被验收覆盖 |
|---|---|---|---|
| **预遮罩占位预算** | 叠加层必须在 `RestMouthReturn` **之前**合成,否则回位只缩放底层,预算基准就错了 | **满足**(第一节第 1、2 项) | **未覆盖**:12 项里没有一条序列的叠加层含 `parted`/`pressed` |
| **统一宿主 speechMask** | 桥接不得按序列传入各自的掩码 | **满足**:1.1.0 的 `ChoreographySequence` 已经没有 `speechMask` 成员,想传也传不了 | **不适用**:1.1.0 上不可能构造出分歧 |
| **连续眨眼衰减** | `baseBlink` 必须真的喂进去、`MotionFrame` 必须用回 `choreographyFrame.blink` | **满足**(第一节第 3 项) | **弱覆盖**:用例 7 的判据是"越界 0 帧、最长全闭 ≤ 24 帧、确实眨了",阈值切换和连续衰减都能通过 |

也就是说:接线是对的,缺的是**能把两版分开的输入**。
第零节那两样东西补完,再加下面这一条最短的回归,就够了 ——
它直接就是 B1 的条件,放进 `ChoreographyIntegration.swift` 大约十行:

```swift
// 底层轻抿唇 + 微张唇叠加层,说话开始/结束时底层不得跳变。
// 1.0.0 的核心在这里会跳 0.272。
c.setExpression(.pressedLips); tick(c, frames: 24)
c.play(ChoreographySequence(id: "regress.parted",
    steps: [ChoreographyStep(.partedLips, blend: 0.3, hold: 30, label: "parted")]))
tick(c, frames: 24)
let quiet = (c.lastFrame.expressionPose ?? ExpressionPose()).pressed
c.playAudio(audio)
var worst = 0.0, previous = quiet
while c.isAudioPlaying {
    RunLoop.current.run(until: Date().addingTimeInterval(1.0/24.0)); c.renderFrame()
    let p = (c.lastFrame.expressionPose ?? ExpressionPose()).pressed
    worst = max(worst, abs(p - previous)); previous = p
}
tick(c, frames: 24)
worst = max(worst, abs((c.lastFrame.expressionPose ?? ExpressionPose()).pressed - previous))
record("遮罩不得使底层表情跳变", worst < 0.02, ["max_pressed_step": worst, "pressed_quiet": quiet])
```

---

## 四、审美验收:四条实机输入序列

**我不对下面任何一条给出合格判断。** 连续、有界、测试通过都已经成立了，
但那三件事都不等于自然。下面只给能稳定复现该现象的最短输入,以及该看什么。

四条都建议走**已有的** `tests/ChoreographyPreview.swift` —— 它已经在逐帧取
`PortraitView.imageLayer.contents` 并出 GIF + 曲线。把 `main()` 中间那段剧情换掉即可，
不需要新工具。三条里要用到一个"按住不放"的序列,直接内联构造:

```swift
func held(_ key: ExpressionKey, _ id: String, intensity: Double = 1) -> ChoreographySequence {
    ChoreographySequence(id: id, steps: [
        ChoreographyStep(key, intensity: intensity, blend: 0.3, hold: 30, label: id)])
}
```

### V1 · 语音结束附近取消 parted 序列(0.147 重开)

```swift
label = "微张唇序列";   c.play(held(.partedLips, "visual.parted")); step(24)
label = "播放语音";     c.playAudio(audio); step(24)
label = "语音结束同刻取消"; while c.isAudioPlaying { step(1) }; c.stopSequences(); step(36)
```

看什么:语音停下之后,嘴有没有先张开一点再合上。曲线上 `parted` 会升到
约 0.147 再回到 0(约 0.4 秒内走完)。**要判断的是:这一下像"嘴放松下来"，
还是像咽了一口。** 如果像后者,可改的地方有两个:把取消提前到语音还在播的时候
(V1 变体:`c.stopSequences()` 放在 `while` 之前,曲线上就完全没有这一下)，
或把该序列的 `cancelBehavior` 改成更短的 `.release(blend: 0.1)`。

### V2 · 遮罩期间底层从 0.85 降到 0.578

```swift
label = "轻抿唇";       c.setExpression(.pressedLips); step(24)
label = "叠加微张唇";   c.play(held(.partedLips, "visual.parted")); step(24)
label = "播放语音";     c.playAudio(audio); while c.isAudioPlaying { step(1) }; step(24)
label = "停止编排";     c.stopSequences(); step(36)
```

看什么:序列一起来,抿唇的力度就从 0.85 掉到 0.578,并且**在整段语音里保持不变**，
序列结束才回到 0.85。**要判断的是:这一次性的减弱看不看得出来、像不像表情变虚了。**

一句必要的说明,免得把它当成可以调掉的参数:这一下减弱是**权重预算逼出来的**，
不是设计选择。`pressed 0.85 + parted 0.32 = 1.17 > 1`,渲染器的四个权重和必须 ≤ 1，
所以叠加层要显示就一定得让出位置。能选的只是它**什么时候发生**:
1.1.0 让它发生在序列起落时(一次,且之后不动),1.0.0 让它跟着说话开关来回跳(0.272)。

### V3 · 说话中的 pressed

```swift
label = "播放语音";     c.playAudio(audio); step(12)
label = "说话中起抿唇序列"; c.play(held(.pressedLips, "visual.pressed")); step(24)
                         while c.isAudioPlaying { step(1) }
label = "停止编排";     c.stopSequences(); step(36)
```

看什么:抿唇的贴图压在一张正在开合的嘴上。**要判断的是:这两者同时出现是不是矛盾。**
默认掩码只压 `parted`,理由是现有 App 本来就允许手选的轻抿唇在播放时保留；
但现在序列可以在**句子中途**起一个抿唇,这是 0.3.5 做不到的。
如果看着不对,一行就能改掉 —— 在 `ChoreographyBridge.defaultConfiguration` 里:

```swift
ChoreographyConfiguration(vocabulary: hostVocabulary(), seed: seed,
                          speechMask: .speechOwnedStrict, ambient: ambient)
```

### V4 · 半闭眼时的自动眨眼

```swift
// 待机必须开着,否则 baseBlink 恒为 0,看不到自动眨眼。
label = "半闭眼按住"; c.play(held(.resting, "visual.halfRest", intensity: 0.45)); step(24*10)
```

看什么:眼皮停在 45% 闭合,期间 `BlinkClock` 会照常眨 1~3 次，
但眨眼幅度被按比例衰减到 55%。**要判断的是:这样一次浅眨像正常眨眼还是像抽动。**
这正是 `ambientEyeRest` 在待机时的形态(它的 `intensity` 就是 0.45)。
若像抽动,把 `SequenceLibrary.ambientEyeRest` 的 `intensity` 提到 1.0
(全闭时衰减到 0,就没有浅眨了),或把它从待机库里去掉。

---

## 五、仍然只能在本地验证的事

* 上述三件版本证明做完后**重跑 12 项**,并让报告带上核心指纹。
* `reduce-motion.patch` 打上后重新构建。我在 Linux 上验证了它所依赖的模块行为
  (不补播、显式序列不受影响),**但这段 AppKit 代码本身我没有编译过**，
  这里没有 macOS SDK。
* V1~V4 四段观感,以及补上 `preview/` 里那两个文件。
* `-lExpressionChoreography` 链接的那份模块与 app 构建的那份是否同源。

## 六、没做的事

* 没有改渲染器,也没有碰光影、背景或素材。
* 没有碰 28 级人物台阶,它仍然单独记在原处。
* 没有另建框架:新增测试都落在既有的 `CompositionAcceptanceTests` / `LifecycleTests` 里，
  四段观感脚本用的是你们已有的 `ChoreographyPreview.swift`。

---

# 附录 · 第二轮(1.1.0 对齐包)复核 · 20260911

对象:`动作编排-第二轮对齐与眼部合成任务-20260911/local-1.1.0-delivery`。
只看相对上一轮的**新差异**,已经对的不再重提。

## 一、版本缺口:已补上,判据确实有判别力

`ChoreographyJumpFixes.swift` 同一份判据同时跑 1.0.0 与 1.1.0,得 **0/3 与 3/3**。
这正是我上一轮要的东西。三点确认:

* **B1** 复现出的 0.272 与我这边两版实测完全一致。
* **B3** 你们的判断对:数值判据照不出来(两条序列用同一个遮罩本来就不打架),
  改用反射看 `ChoreographySequence` 里还有没有 `speechMask` 字段,才有判别力。
* **眨眼那条判据的自我修正值得记一笔。** 第一版用"单帧步进 < 0.9",在 1.1.0 上
  量到 1.0 判 FAIL —— 那 1.0 是 `BlinkClock` 自己的上升沿(0.055 秒,24fps 下
  不到 1.4 帧),与门控无关。把判据换成"峰值 ≈ 1−rest"是对的。
  **不过这条判据本身现在过时了**:1.2.0 里峰值不再是 `1−rest`,而是 1.0,
  最终眼皮峰值也是 1.0。新的判据见 `docs/EYELID-CONTRACT.md` 第四节的行程表。

`module-hashes.json` 57 项全对 + 桥接逐字节相同,版本这件事在这一轮是清楚的。
构建时链接的守卫,用更新后的 `apply-version-guard.patch`(现在读
`ChoreographyVersion.current`,要求 >= 1.2.0)。

## 二、减弱动态效果:你们的接法比我给的那版好,不要再打我的补丁

我上一轮的 `reduce-motion.patch` **已作废**,文件改名为
`superseded-reduce-motion.patch` 以免误用。你们的版本更好,三点具体的:

* **一个读取点 + 一个写入点。** `reduceMotion` 计算属性 + `applyChoreographyIdle()`,
  并且把 `renderFrame` 里原来那句 `NSWorkspace.shared...` 也改成读同一个属性。
  我那版把同步塞在 `renderFrame` 里,读取点其实还是两个。
* **`show()` 里的重新同步。** 这是我没看出来的真实顺序依赖 —— 我那版靠
  "反正每帧都会同步"顺带covered住了,但那是巧合,不是设计。你们把它写明了。
* **`reduceMotionOverride` 让它可测。** 我那版没有测试入口,三项实机用例
  (26 秒自动峰值 0.0 / 运行中打开 0.45→0.0 / 运行中关闭 0.0→0.176)
  在我那版上写不出来。

四条路径(init、`toggleIdle`、`show`、`accessibilityDisplayOptionsDidChangeNotification`)
都走同一个写入点,`deinit` 里原有的 `NSWorkspace.shared.notificationCenter.removeObserver(self)`
覆盖了新加的观察者。**没有发现问题。**

语义也对:减弱动态效果只关自动编排,手动表情与显式序列照常 ——
与 app 既有做法一致,也与模块 `setIdleEnabled` 的语义一致
(它只关自排行为;正在跑的显式序列不受影响,重新打开从当前时刻重新计时、不补播)。

## 三、三段预览

* **A 段(句尾附近取消)** —— 孔径 0 → 0.319 → 0,单峰、连续,与 C2 描述一致。
  你们的观察("不像吞咽,唇线轻微松开,峰值帧与闭合帧嘴部最大 59 / 平均 0.90")
  记下了;按任务书,这是本地观察而非用户验收,**我不据此判合格**。
  也确认了 C3 那条规避办法确实有效(在语音结束**之前**取消就什么都看不到)。
* **B 段(说话时轻抿唇)** —— 关键证据是那句像素核对:编排给的 `pressed=0.85`
  与手选 `setExpression(.pressedLips)` 给的 `pressed=0.85`,**嘴部逐像素完全相同
  (最大 0 / 平均 0.00)**。这就把问题归位了:好不好看是 app 既有的抿唇行为,
  不是编排引入的。要不要压住,用 `speechMask: .speechOwnedStrict` 一行切换。
* **C 段(半闭眼眨眼)** —— 这一段找出了真问题,见下。

## 四、C 段:是 1.1.0 的缺陷,我改了

你们的措辞是"这不是 1.1.0 的缺陷 …… 是宿主 `max(rest, blink)` 与模块比例缩放
叠在一起的结果"。**在归因上我不同意,并且这一处该算我的。**

渲染器早就在一处合成眼皮闭合:`max(pose.rest, frame.blink)`。
1.1.0 又在上游乘了一次 `1 − overlay.rest`,那就是**第二个合成点**——
正是这套设计一直在避免的重复控制。两者叠起来是
`max(rest, blink × (1 − rest))`,而 `1 − rest > rest` 只在 `rest < 0.5` 成立,
所以 `rest >= 0.5` 时眨眼在数学上不可能露出来,与素材和帧率都无关。
你们测到的 0.55 档 5 / 0.08 就是它。

**1.2.0 删掉了那条规则**,渲染器不动。契约、各档实测、边界值、
以及拍摄步骤都在 `docs/EYELID-CONTRACT.md`。一句话:
`rest = 0.55` 时行程从 **0.000 变成 0.450**,最终峰值到底(1.0)。

## 五、仍然只能本地做的

* 换 1.2.0 重跑三套实机用例 + C 段五档拍摄(契约文档第七节给了脚本与判据)。
* `ChoreographyJumpFixes.swift` 里眨眼那条判据要按第四节的行程表更新。
* `preview/` 三段这次在包里了,谢谢;C 段请按新版重拍一次。
