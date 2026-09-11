# 眼皮闭合契约 · 1.2.0

## 一、四个量,分清楚

| 量 | 由谁产出 | 含义 |
|---|---|---|
| `input.basePose.rest` | 宿主 `ExpressionTransition.sample(at:)` | **基础表情**要求的眼皮闭合量。手选「闭眼休息」时是 1 |
| `overlay.rest` | 模块的序列叠加层 | **序列**要求的眼皮闭合量 |
| `output.pose.rest` = `MotionFrame.expressionPose.rest` | 模块 `PoseWeights.layer(base:overlay:)` | 上面两个合成后的**表情闭合量**,渲染器读到的就是它 |
| `output.blink` = `MotionFrame.blink` | 宿主 `BlinkClock`(除非某一拍用 `.hold` 替换) | **眨眼**要求的眼皮闭合量 |

两条必须记住的:

1. **`rest` 和 `blink` 是对同一个物理量的两份请求**,不是"基础量 + 额外量",
   也不是"最终量"。它们都在 `0...1` 上表示"眼皮下垂到哪里"。
2. **前三个 `rest` 是三个不同的量,不能互相代入。** 1.1.0 的错误正是拿
   `overlay.rest` 去缩放 `blink`,于是手选的闭眼(走 `basePose.rest`)不缩放、
   序列给的闭眼(走 `overlay.rest`)缩放,同一件事有两套待遇。

## 二、只在一处合成

```swift
// PortraitRenderer.blinkAmount(for:) —— 0.3.5,未改动
func blinkAmount(for frame: MotionFrame) -> Double {
    func unit(_ x: Double) -> Double { x.isFinite ? min(1, max(0, x)) : 0 }
    let pose = frame.expressionPose ?? ExpressionPose.target(frame.expression)
    return max(unit(pose.rest), unit(frame.blink))
}
```

**最终眼皮闭合 = `max(pose.rest, blink)`,在渲染器里算一次,别处不再算。**
"谁要求眼皮更低,就听谁的。"

由此直接推出三条,它们是结构性的,不依赖任何参数:

* **不会反向睁开。** 结果永不小于 `pose.rest`,因为 `max` 的一边就是它。
* **上游不得预先衰减任何一边。** 任何 `blink *= f(rest)` 或 `rest *= f(blink)`
  都是第二个合成点,会造成重复衰减。
* **连续、有界。** 两个连续有界函数取 `max` 仍然连续有界,值域仍是 `0...1`。

`layer(base:overlay:)` 是**姿态**的合成点,产出 `pose.rest`;它与眨眼无关,
也从不读 `blink`。两个合成点各管各的,互不穿越。

## 三、1.2.0 改了什么

删掉一条规则,没有加任何东西:

```swift
// 1.1.0 —— 已删除
} else if configuration.blinkFadesUnderRestOverlay && maskedOverlay.rest > 0 {
    blink *= 1 - maskedOverlay.rest
    overridden = true
}
```

它是第二个合成点。与渲染器的 `max` 叠在一起就成了
`max(rest, blink × (1 − rest))`,而 `1 − rest > rest` 只在 `rest < 0.5` 成立 ——
**所以 `rest ≥ 0.5` 时眨眼在数学上根本不可能露出来**,与眨眼曲线、帧率、素材都无关。
本地实测 `rest≈0.55` 时眼部像素差最大 5、平均 0.08,就是这条。

配置项 `blinkFadesUnderRestOverlay` 一并删除:那条规则是错的,不是可选的。
`StepBlink.hold(_:)` 保留 —— 它**替换**眨眼的请求而不是缩放它,
`.hold(0)` 表示"这一拍不要眨眼",最终显示 `max(rest, 0) = rest`,不产生第二次衰减。

`SequenceLibrary.briefEyeRest` 里那个 `.hold(0)` 在 1.1.0 就去掉了,现在理由更清楚:
它把眼皮闭到 1,`max` 自己就把眨眼盖住了,不需要额外压制。

## 四、各档实测(Linux,两版同一份输入)

眨眼曲线用 `BlinkClock` 自己的形状(0.055 秒上升、保持到 0.125 秒、0.22 秒落回)。

| `pose.rest` | 1.1.0 眨眼峰值 | 1.1.0 最终峰值 | 1.1.0 行程 | **1.2.0 眨眼峰值** | **1.2.0 最终峰值** | **1.2.0 行程** | 可见帧(24fps) |
|---:|---:|---:|---:|---:|---:|---:|---:|
| 0.00 | 1.000 | 1.000 | 1.000 | 1.000 | 1.000 | **1.000** | 5 |
| 0.30 | 0.700 | 0.700 | 0.400 | 1.000 | 1.000 | **0.700** | 4 |
| 0.55 | 0.450 | 0.550 | **0.000** | 1.000 | 1.000 | **0.450** | 4 |
| 0.70 | 0.300 | 0.700 | **0.000** | 1.000 | 1.000 | **0.300** | 3 |
| 1.00 | 0.000 | 1.000 | 0.000 | 1.000 | 1.000 | **0.000** | 0 |

边界值,明确写死:

* **行程 = `1 − rest`。** 眼皮总能闭到底(最终峰值恒为 1),剩多少路就走多少。
* **可见时长 = `0.22 − 0.15 × rest` 秒**(`blink > rest` 的那段窗口)。
  24fps 下是 5.28 / 4.20 / 3.30 / 2.76 / 0 帧的量;表里的整数是这段窗口落在
  24fps 采样格上的实际帧数,触发时刻不同可能相差一帧。
* **`rest = 0`:** 与没有本模块时逐点相同,原眨眼一点不动。
* **`rest = 1`:** 最终恒为 1,眨眼不产生任何变化,也不反向睁开。

## 五、还需要在 macOS / 用眼睛确认的

Linux 上确定的只有数值。下面这些这里做不了:

* **实际眼皮画面。** `rest = 0.55` 时行程 0.45、可见 4 帧,比 1.1.0 的 0 帧行程
  一定更明显,但"明显"到什么程度要看像素。请按第七节拍一遍,
  用你们已有的眼部像素量化重做一次 C 段对照。**我不宣称视觉验收通过。**
* **高 `rest` 时窗口变短。** `rest = 0.70` 只有 3 帧。数值上它是一次完整闭合,
  但是否还读得出"眨了一下",只有画面能回答。若判定太短,第六节有一个可选改法。
* **`.hold` 与眨眼同时在飞。** `.hold` 是立即替换,如果一拍在眨眼中途开始,
  `blink` 会从当前值直接跳到 `hold` 值。库里没有序列用 `.hold`,所以现在碰不到;
  作者显式使用时是他自己的选择。

## 六、可选:如果 3 帧太短(需要改宿主,默认不改)

`max` 会把眨眼曲线**截掉** `blink < rest` 的那一段,所以 `rest` 越高、可见时间越短。
另一种合成是把眨眼映射到剩余行程上:

```swift
// 可选替代,非本轮默认:blinkAmount(for:) 里把 max 换成
return unit(pose.rest) + (1 - unit(pose.rest)) * unit(frame.blink)
```

差别只在 `0 < rest < 1`:

| | `max`(现状) | 剩余行程映射 |
|---|---|---|
| `rest = 0` / `rest = 1` | 与对方逐点相同 | 与对方逐点相同 |
| `rest = 0.55` 行程 | 0.45 | 0.45 |
| `rest = 0.55` 可见时长 | 0.1375 s | 0.22 s(完整曲线) |
| 观感 | 一次**短促**的到底闭合 | 一次**完整形状**的闭合,幅度较小 |

两者行程相同,只是时间形状不同。**我不替你们选** —— `max` 是现状、零改动、
且手选表情的行为逐点不变,所以本轮默认不动;如果拍出来觉得太短促,这一行就是改法。
真要改,它属于宿主渲染器,由本地负责。

## 七、拍摄步骤(接着你们已有的 C 段)

沿用 `tests/ChoreographyLookPreviews.swift`,只改 rest 档位,拍五段:

```swift
// 手动眨眼,免得自动眨眼混进测量窗口
func rung(_ rest: Double) -> ChoreographySequence {
    ChoreographySequence(id: "look.rest.\(rest)", steps: [
        ChoreographyStep(.resting, intensity: rest, blend: 0.3, hold: 30, label: "rest \(rest)")])
}
// rest = 0 那一档不播序列,直接拍原眨眼作为对照
for rest in [0.0, 0.30, 0.55, 0.70, 1.0] { ... c.play(rung(rest)) ... 触发一次眨眼 ... }
```

每档要记的,和你们 C 段一样:眼部**峰值帧 vs 未眨眼帧**的最大/平均像素差。
判据只有一条,而且是对照式的:**`rest = 0.55` 这一档的眼部像素差,
应当与 `rest = 0.30` 在同一量级**(你们测到的是 179 / 3.76),
而不是 1.1.0 那次的 5 / 0.08。`rest = 1.00` 那一档应当是 0 / 0.00。

## 八、顺带更正,以及一个不属于本轮的发现

### 更正:四权重之和 ≤ 1 不是渲染器的要求

我上一轮说"渲染器的四个权重和必须 ≤ 1,所以抿唇从 0.85 降到 0.578 是被逼出来的"。
**这句话是错的。** 读了 `PortraitRenderer` 之后:

```swift
// mouthPose(for:) —— 渲染器自己就把这一对归一化了
let total = max(1, unit(pose.smile) + unit(pose.pressed))
let smile = unit(pose.smile)/total, pressed = unit(pose.pressed)/total
```

* `rest` 只进 `blinkAmount`,
* `parted` 只进 `mouthOpening`,
* `smile` 与 `pressed` 成对进 `mouthPose`,**而且渲染器自己会归一化**。

渲染器**没有**四权重求和的约束。0.578 这个数来自我 `layer()` 的分配算法,
是可以换的,正如任务书所说"并不是唯一可能的数学结果"。

### 同一族的一个新发现(本轮不动)

`layer()` 让 `rest` 和嘴部权重共用一份预算,于是:

| 手选「闭眼休息」时叠加 | 合成后 `pose.rest` | 眼皮被顶开 |
|---|---:|---:|
| ambient microSmile(0.55×0.32) | 0.824 | 17.6% |
| softSmile 1.0 | 0.680 | 32.0% |
| smile 1.0 | 0.200 | 80.0% |

也就是说:用户选了闭眼休息,待机时一条自排的微笑序列会把眼睛**掀开** 17.6%。
渲染器并不需要这个耦合 —— 眼和嘴在它那里是两条独立通路。

按任务书"保持本轮范围,不必为此重写混合策略",**本轮没有改**。
方向记在这里供下一轮取舍:按通道分预算(眼一份、嘴一份),而不是四权重共用一份。
