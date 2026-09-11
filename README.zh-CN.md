# ExpressionChoreography（表情与动作编排层）

一个小而独立的 Swift 模块：把人物已有的六种表情组织成**可描述、可组合、可取消、
带明确优先级**的短序列。只做编排，不做别的。

它从外部接收时间、事件和宿主自身的状态，返回表情权重、眨眼值，以及"是否还需要
继续刷新"。它不自建时钟、不建计时器、不开线程、不读屏幕、不联网、不接任何大模型
或语音服务。核心只依赖 Foundation。

* `Sources/ExpressionChoreography/` —— 可移植核心。
* `integrations/ChoreographyHostKit/` —— 映射到 `MotionFrame` / `ExpressionPose`
  的接入适配器，另含一个编译校验用的宿主类型副本，以及 `DesktopController.renderFrame()`
  的无界面复现。
* `examples/ChoreographyDemo/` —— 命令行 `choreo-demo`，逐帧输出 CSV / JSONL。
* `Tests/` —— 97 项 XCTest；实际编译与运行情况见 [docs/TEST-LOG.md](docs/TEST-LOG.md)。
* [docs/INTEGRATION.md](docs/INTEGRATION.md) —— 四个插入点。

---

## 本模块不做什么

先写边界，因为边界比功能清单更要紧。

* **不修复"说话时光影和背景跳变"。** 它做不到：它完全不碰渲染器、不碰光影设置、
  不碰背景，也不碰任何照片或视频素材。那部分属于本地执行方的渲染器工作。
* **不产出新的面部表情素材。** 每一拍最终都落回 `ExpressionPose.target(_:)` 里
  已有的六组权重。示例序列用来验证框架，不代表已经做出新表情。真正的表情素材
  仍须回到原来的四张照片和四段视频。
* **不新增姿势、手势、头颈旋转、物件或服装。**
* **绝不生成口型。** `ChoreographyOutput` 里根本没有开口度和嘴宽字段，因此在结构上
  就不可能与 `MouthTimeline`、`MouthEnvelope` 或静音闭唇争抢；不生成新的字音时间轴，
  也不会把辅音闭合平滑掉。
* **不重写 `DesktopController`。** 适配是叠加式的：四个插入点，不做替换。

---

## 先读已有能力——哪些没有重做

0.3.4 已经把若干问题解决得很好，这里一个都没有换名重写，而是直接使用。

| 已有实现，原样保留 | 模块在它周围新增的部分 |
| --- | --- |
| `ExpressionTransition` —— 单次可被打断的过渡 | 多拍具名序列，**叠加**在它当前显示的姿态之上 |
| `BlinkClock` —— 眨眼时序与形状 | 每一拍的眨眼指令：保持睁/闭，或向这只时钟请求一次眨眼 |
| `MouthTimeline` —— 字级口型 | 无。模块没有任何口型输出 |
| `MouthEnvelope` —— 音量回退 | 无 |
| `RestMouthReturn` —— 语音结束后的嘴形回位 | 一个语音掩码：说话期间模块不再驱动 `parted`，何时回来仍由这一个所有者决定 |
| `HairPhysics`、身体位移、窗口摆放 | 无 |
| `SpeechDemo` —— 无声预览 | 无；演示把它当作输入重放 |

真正新增的是：

* **序列。** 一串具名的拍子，每拍含目标表情、强度、渐入时长、保持时长、缓动和眨眼
  指令。开始、持续、结束都可表达，重复也可以。
* **优先级仲裁。** 同一时刻只有一条序列拥有表情通道，因此两个事件不可能交替争抢同
  一个参数。准入方式为 `preempt`、`rejectIfBusy` 或 `enqueue`（有界队列）。
* **从当前可见状态切换与取消。** 新序列或取消动作一律从屏幕上当前的姿态继续，绝不
  先跳回自然再过渡。
* **明确的隐藏 / 休眠 / 恢复约定。** 离开屏幕即丢弃正在运行和排队的动作；恢复时覆盖
  层从零开始，待机倒计时从恢复那一刻重新计。不积压、不回放。
* **外部时间约定。** NaN、无穷、时间倒退、超大时间步各有明确且有测试的结果，且都不会
  传到渲染器。
* **可关闭、可复现的自然待机行为。** 自动行为可以整体关掉；打开时所有随机都来自注入
  的种子，同样输入产出同样帧。
* **"是否还需要刷新"的答复，** 让 App 现有的计时器在序列结束后能正确停止。
* **对外部传入数值的校验与夹取。**

---

## 各项状态由谁拥有

一句话：**凡是持久的都归宿主，模块只拥有一层临时覆盖。** 覆盖层必定回到零，所以
模块不会留下看不见的状态。

| 状态 | 所有者 | 说明 |
| --- | --- | --- |
| 当前选中的表情（`expression`、菜单勾选） | **宿主** | 模块从不写它 |
| `ExpressionTransition`（基础过渡） | **宿主** | 采样后作为 `basePose` 传入 |
| 四个权重上的序列覆盖层 | **模块** | 必定归零 |
| 最终合成的 `ExpressionPose` | **模块**合成，**宿主**渲染 | `layer(base:overlay:)` |
| `BlinkClock` 状态、眨眼形状与间隔 | **宿主** | 模块只能在一拍内保持某个值，或请求触发一次 |
| 帧里的 blink 值 | **模块**返回 | 除非某一拍覆盖，否则就是宿主自己的值 |
| `mouth`、`mouthWide` | **宿主** | 模块没有这两个字段 |
| `MouthTimeline`、`MouthEnvelope`、静音闭唇 | **宿主** | 原样不动 |
| `RestMouthReturn` 与嘴形回位 | **宿主** | 模块只是在说话期间不驱动 `parted` |
| `HairPhysics`、`movement`、窗口位置、光影 | **宿主** | 原样不动 |
| 帧计时器、RunLoop、线程 | **宿主** | 模块只提供一个布尔项 |
| 窗口显示与休眠 | **宿主** | 通过 `setPresentation` 告知模块 |
| 自然待机开关 | **宿主** | 通过 `setIdleEnabled` 同步 |
| 序列队列与仲裁 | **模块** | 隐藏、休眠或长停顿时清空 |

---

## 快速上手

```swift
import ExpressionChoreography

let director = ChoreographyDirector(
    configuration: ChoreographyConfiguration(
        vocabulary: .version0_3_4,      // 或直接用宿主的 ExpressionPose.target 表
        seed: 0x5EED0001,               // 待机行为可复现
        ambient: AmbientConfiguration() // 传 .disabled 可整体关闭自动行为
    )
)

director.play(SequenceLibrary.softSmileGreeting())   // 自然 → 微微笑 → 自然

// 每渲染一帧调用一次：
let output = director.update(
    time: elapsed,                                   // 宿主的时间
    input: ChoreographyInput(basePose: currentBasePose,
                             baseBlink: currentBlink,
                             isSpeechActive: speaking)
)

output.pose                     // 合成后的权重，有限且在预算内
output.blink                    // 除非某一拍覆盖，否则是宿主自己的值
output.requestsBlinkTrigger     // 单帧边沿，用于 BlinkClock.trigger(at:)
output.needsContinuousUpdates   // 或进 App 现有的计时器条件
```

写一条序列：

```swift
let thinking = ChoreographySequence(
    id: "mood.thinking",
    steps: [
        ChoreographyStep(.pressedLips, blend: 0.30, hold: 0.80, label: "轻抿唇"),
        ChoreographyStep(nil,          blend: 0.40, label: "回到自然"),   // nil 表示回到宿主的姿态
    ],
    priority: .user,
    admission: .preempt,
    cancelBehavior: .release(blend: 0.38),
    speechMask: .speechOwned
)
```

`SequenceLibrary` 自带 7 条显式序列和 2 条待机序列，全部只用已有的六种表情：
`softSmileGreeting`、`warmSmile`、`consideration`、`briefEyeRest`、`attentive`、
`urgentSmile`、`speakingSmile`、`ambientMicroSmile`、`ambientEyeRest`。

---

## 几处需要知道的行为

**权重预算。** 渲染器把这四个数当作混合权重，现有自检也已经断言过渡中途满足
`smile + pressed <= 1`。叠加使用"剩余余量"而不是相加：

```
result = base * (1 - min(1, overlay.total)) + overlay
```

因此只要 `base.total <= 1` 就保证 `result.total <= 1`，而满强度覆盖就是一次普通的
交叉淡入。宿主能产生的每一种姿态都满足这个前提；即便传进来的 base 本身已经超预算，
模块也保证不会让它更糟。

**说话期间。** `isSpeechActive` 为真时，序列 `speechMask` 里的分量不输出。默认是
`.speechOwned`（只含 `parted`），与现有 App 的行为一致：播放时把 `parted` 归零，而
轻抿唇的选择依然保留。笑形不受影响。若希望更严格，可用 `.speechOwnedStrict`，连
`pressed` 一起压住。解除掩码是一步到位、不带自己的斜坡，因为决定嘴形怎么回来的只有
`RestMouthReturn` 一个所有者——它由宿主作用在合成后的姿态上。

**时间。** 模块把宿主时钟转换成单调递增的内部时钟：

| 输入 | 结果 |
| --- | --- |
| NaN 或无穷 | 步长为 0，状态冻结，`timeAnomaly == .nonFinite` |
| 时间倒退 | 步长为 0，重新对齐，`.wentBackwards` |
| 步长超过 `maximumTimeStep`（0.5 秒） | 该帧不推进任何动画，正在运行和排队的动作全部取消，覆盖层按 `releaseBlend` 淡回基础姿态。`.largeStep` |
| 其它 | 正常推进 |

0.5 秒这个阈值与 `HairPhysics` 处理窗口恢复时用的一致；而"取消而不是快进"正是恢复
时不会落在夸张帧上的原因。

**可复现性。** 随机只来自 `SeededGenerator`（SplitMix64），由配置的种子驱动；序列
种子用 FNV-1a 推导，而不用每个进程随机加盐的 `String.hashValue`。同样的种子加同样的
时间戳复现每一帧——`choreo-demo --seed N` 跑两次字节完全一致。

**上限。** 每条序列最多 32 拍，单拍渐入最长 10 秒、保持最长 30 秒，单趟最长 180 秒，
最多重复 64 次，队列深度 8，标识符最长 64 字符。超范围的数值会被夹取；结构性问题
（没有拍、标识符为空、时长非有限）在 `submit` 阶段就以
`ChoreographyValidationError` 拒绝，而不是等到渲染时。

---

## 命令行演示

```
swift run choreo-demo --list
swift run choreo-demo --scenario greeting
swift run choreo-demo --scenario speech --format jsonl --fps 24
swift run choreo-demo --scenario ambient --seed 42 --duration 240
```

11 个场景覆盖了过渡途中反向切换、打断、取消、说话掩码、待机关闭、隐藏/恢复、大时间步
和排队。输出每帧一行：宿主时间、内部时钟、当前序列与拍、基础权重、覆盖权重、合成权重、
眨眼、口型两列、是否仍需刷新、时间异常、以及该帧的通知。它不画人物，不需要渲染器、
素材或窗口。

各场景的记录输出在 `examples/output/`，用 `./examples/run-all.sh` 可重新生成。

---

## 接入

见 [docs/INTEGRATION.md](docs/INTEGRATION.md)。简述：加入这个包，把
`integrations/ChoreographyHostKit/ChoreographyBridge.swift` 复制进 App，然后在
`DesktopController` 里做四处小改动——`renderFrame()` 中现有
`expressionTransition.sample(at:)` 之后、现有 `RestMouthReturn` 那一行之前插入一处；
眨眼触发一处；`updateTimer()` 的 `needed` 表达式里加一项；以及
`show()`/`hide()`/`willSleep()`/`didWake()`/`toggleIdle()` 里的生命周期调用。

## 测试

97 项 XCTest，已实际编译并运行。到底在什么环境跑了什么、以及这里查不到的部分，都记在
[docs/TEST-LOG.md](docs/TEST-LOG.md)，原始日志见 `docs/logs/build-and-test.txt`。

```
swift build
swift test
```

需要 Swift 5.9 或更高。核心与适配器都只依赖 Foundation，因此在 Linux 和 macOS 13+
上都能构建。
