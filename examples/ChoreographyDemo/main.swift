import Foundation
import ExpressionChoreography
import ChoreographyHostKit

// A head-less frame dump. It prints numbers, not pictures: there is no renderer,
// no window and no character artwork here, and none is needed to check that the
// choreography layer behaves.
//
//   swift run choreo-demo --list
//   swift run choreo-demo --scenario greeting
//   swift run choreo-demo --scenario speech --format jsonl --fps 24

// MARK: - Arguments

struct Options {
    var scenario = "greeting"
    var format = "csv"
    var fps = 24.0
    var seed: UInt64 = 0x5EED_0000_0001
    var duration: Double?
    var listOnly = false
}

func parseOptions(_ arguments: [String]) -> Options {
    var options = Options()
    var index = 0
    while index < arguments.count {
        let argument = arguments[index]
        func value() -> String? {
            index += 1
            return index < arguments.count ? arguments[index] : nil
        }
        switch argument {
        case "--scenario", "-s": options.scenario = value() ?? options.scenario
        case "--format", "-f": options.format = value() ?? options.format
        case "--fps": options.fps = Double(value() ?? "") ?? options.fps
        case "--seed": options.seed = UInt64(value() ?? "") ?? options.seed
        case "--duration", "-d": options.duration = Double(value() ?? "")
        case "--list", "-l": options.listOnly = true
        case "--help", "-h":
            print("""
            choreo-demo — per-frame dump of the expression choreography layer

              --scenario, -s   scenario name (see --list)
              --format,   -f   csv | jsonl          (default csv)
              --fps            frames per second    (default 24, the app's rate)
              --seed           deterministic seed   (default 0x5EED00000001)
              --duration, -d   override run length in seconds
              --list,     -l   list scenarios and exit
            """)
            exit(0)
        default: break
        }
        index += 1
    }
    return options
}

// MARK: - Scenario model

/// One scripted thing that happens to the harness at a given time.
struct Cue {
    var at: Double
    var apply: (HostRenderLoopHarness) -> Void
}

struct Scenario {
    var name: String
    var summary: String
    var duration: Double
    var idleEnabled: Bool = false
    var ambient: AmbientConfiguration = .disabled
    var cues: [Cue] = []
    /// Extra host time injected before a frame, used to simulate a stall.
    var timeWarp: (Double) -> Double = { $0 }
    var speech: (Double) -> HostSpeechSample = { _ in .silent }
}

let scenarios: [Scenario] = [
    Scenario(
        name: "greeting",
        summary: "自然 → 微微笑 → 自然, the three-beat base case.",
        duration: 2.6,
        cues: [Cue(at: 0.2) { $0.play(SequenceLibrary.softSmileGreeting()) }]
    ),
    Scenario(
        name: "interrupt",
        summary: "A higher priority 浅笑 cuts into 微微笑 mid-blend and continues from the visible pose.",
        duration: 3.2,
        cues: [
            Cue(at: 0.1) { $0.play(SequenceLibrary.softSmileGreeting()) },
            Cue(at: 0.4) { $0.play(SequenceLibrary.urgentSmile()) },
        ]
    ),
    Scenario(
        name: "reverse",
        summary: "Reverse the base expression mid-transition while a sequence overlay is running.",
        duration: 2.6,
        cues: [
            Cue(at: 0.0) { $0.setExpression(.resting, at: 0.0) },
            Cue(at: 0.15) { $0.play(SequenceLibrary.consideration()) },
            Cue(at: 0.19) { $0.setExpression(.natural, at: 0.19) },
        ]
    ),
    Scenario(
        name: "cancel",
        summary: "Cancel mid-hold: the overlay releases from where it is, never via 自然 first.",
        duration: 2.4,
        cues: [
            Cue(at: 0.1) { $0.play(SequenceLibrary.warmSmile()) },
            Cue(at: 0.7) { $0.cancelAll() },
        ]
    ),
    Scenario(
        name: "speech",
        summary: "A smile held under the existing silent speech preview. The mouth columns are untouched.",
        duration: 7.6,
        cues: [Cue(at: 0.3) { $0.play(SequenceLibrary.speakingSmile()) }],
        speech: { time in
            time >= 0.5 ? HostSpeechSample.silentDemo(at: time - 0.5) : .silent
        }
    ),
    Scenario(
        name: "masked",
        summary: "微张唇 requested during speech is withheld; a smile requested during the same sentence is not.",
        duration: 6.0,
        cues: [
            // Before the sentence: the parted weight is visible.
            Cue(at: 0.2) { $0.play(SequenceLibrary.attentive()) },
            // During the sentence: the same sequence runs, but its parted weight
            // never reaches the pose, so it cannot fight the mouth.
            Cue(at: 1.6) { $0.play(SequenceLibrary.attentive(id: "mood.attentive.during")) },
            // Also during the sentence: a smile is allowed to stay.
            Cue(at: 3.0) {
                var smile = SequenceLibrary.speakingSmile()
                smile.priority = .user
                $0.play(smile)
            },
        ],
        speech: { time in
            time >= 1.0 ? HostSpeechSample.silentDemo(at: time - 1.0) : .silent
        }
    ),
    Scenario(
        name: "aperture",
        summary: "轻抿唇 base under a 微张唇 sequence across a sentence: the rendered aperture moves, and nothing else steps.",
        duration: 6.0,
        cues: [
            Cue(at: 0.0) { $0.setExpression(.pressedLips, at: 0.0) },
            Cue(at: 1.0) {
                $0.play(ChoreographySequence(id: "aperture.parted", steps: [
                    ChoreographyStep(.partedLips, blend: 0.3, hold: 30, label: "微张唇"),
                ]))
            },
            Cue(at: 4.6) { $0.cancelAll() },
        ],
        speech: { time in
            time >= 2.0 && time < 4.0 ? HostSpeechSample.silentDemo(at: time - 2.0) : .silent
        }
    ),
    Scenario(
        name: "idle-off",
        summary: "Idle behaviour off. A manual expression and an explicit sequence still run, and the timer term returns to 0.",
        duration: 3.0,
        idleEnabled: false,
        cues: [
            Cue(at: 0.1) { $0.setExpression(.softSmile, at: 0.1) },
            Cue(at: 0.6) { $0.play(SequenceLibrary.consideration()) },
        ]
    ),
    Scenario(
        name: "ambient",
        summary: "Idle behaviour on. Self-scheduled sequences from the injected seed; rerun with the same seed for identical output.",
        duration: 60.0,
        idleEnabled: true,
        ambient: AmbientConfiguration()
    ),
    Scenario(
        name: "hide-resume",
        summary: "Hide mid-sequence, resume 40 s later. Nothing is replayed and the first frame back equals the base pose.",
        duration: 3.0,
        cues: [
            Cue(at: 0.2) { $0.play(SequenceLibrary.warmSmile()) },
            Cue(at: 0.8) { $0.setPresentation(.hidden, at: 0.8) },
            Cue(at: 1.2) { $0.setPresentation(.visible, at: 41.2) },
        ],
        timeWarp: { time in time >= 1.2 ? time + 40 : time }
    ),
    Scenario(
        name: "time-gap",
        summary: "A 30 s stall in the middle of a sequence: the advance is capped and the overlay fades back to the base pose.",
        duration: 3.0,
        cues: [Cue(at: 0.2) { $0.play(SequenceLibrary.warmSmile()) }],
        timeWarp: { time in time >= 0.9 ? time + 30 : time }
    ),
    Scenario(
        name: "queue",
        summary: "Two queued sequences behind a running one; the higher priority waits at the front.",
        duration: 6.0,
        cues: [
            Cue(at: 0.1) { $0.play(SequenceLibrary.softSmileGreeting()) },
            Cue(at: 0.2) {
                var queued = SequenceLibrary.consideration(id: "queued.consideration")
                queued.admission = .enqueue
                $0.play(queued)
            },
            Cue(at: 0.3) {
                var queued = SequenceLibrary.briefEyeRest(id: "queued.eyeRest", priority: .user)
                queued.admission = .enqueue
                $0.play(queued)
            },
        ]
    ),
]

// MARK: - Output

func format(_ value: Double) -> String { String(format: "%.4f", value) }

let columns = [
    "frame", "host_time", "clock", "sequence", "step",
    "base_smile", "base_rest", "base_pressed", "base_parted",
    "overlay_smile", "overlay_rest", "overlay_pressed", "overlay_parted",
    "pose_smile", "pose_rest", "pose_pressed", "pose_parted",
    "blink", "mouth", "mouth_wide", "mouth_opening",
    "speech_active", "needs_timer", "anomaly", "notices",
]

/// A snapshot of one frame. Values are copied out of the harness immediately,
/// because the harness itself is a single mutating object.
struct Row {
    var values: [String]

    init(frame: Int, hostTime: Double, harness: HostRenderLoopHarness, motion: MotionFrame) {
        let pose = motion.expressionPose ?? ExpressionPose()
        let base = harness.basePose
        let overlay = harness.overlay
        let notices = harness.notices.map { notice -> String in
            let kind: String
            switch notice.kind {
            case .started: kind = "started"
            case .stepChanged(let index): kind = "step\(index)"
            case .finished: kind = "finished"
            case .cancelled(let reason): kind = "cancelled:\(reason.rawValue)"
            case .rejected(let reason): kind = "rejected:\(reason.rawValue)"
            }
            return "\(notice.sequenceID)#\(kind)"
        }.joined(separator: " ")
        values = [
            "\(frame)", format(hostTime), format(harness.directorClock),
            harness.activeSequenceID ?? "", harness.activeStepLabel ?? "",
            format(base.smile), format(base.rest), format(base.pressed), format(base.parted),
            format(overlay.smile), format(overlay.rest), format(overlay.pressed), format(overlay.parted),
            format(pose.smile), format(pose.rest), format(pose.pressed), format(pose.parted),
            format(motion.blink), format(motion.mouth), format(motion.mouthWide), format(harness.mouthOpening),
            motion.speechActive ? "1" : "0", harness.needsTimer ? "1" : "0",
            harness.timeAnomaly?.rawValue ?? "", notices,
        ]
    }
}

func emit(_ rows: [Row], format outputFormat: String) {
    switch outputFormat {
    case "jsonl":
        for row in rows {
            let pairs = zip(columns, row.values).map { name, value -> String in
                let numeric = Double(value) != nil && !["sequence", "step", "anomaly", "notices"].contains(name)
                return numeric ? "\"\(name)\":\(value)" : "\"\(name)\":\"\(value)\""
            }
            print("{" + pairs.joined(separator: ",") + "}")
        }
    default:
        print(columns.joined(separator: ","))
        for row in rows {
            print(row.values.map { $0.contains(",") ? "\"\($0)\"" : $0 }.joined(separator: ","))
        }
    }
}

// MARK: - Run

let options = parseOptions(Array(CommandLine.arguments.dropFirst()))

if options.listOnly {
    print("scenarios:")
    for scenario in scenarios {
        let name = scenario.name.padding(toLength: 12, withPad: " ", startingAt: 0)
        print("  \(name) " + String(format: "%5.1fs", scenario.duration) + "  " + scenario.summary)
    }
    exit(0)
}

guard let scenario = scenarios.first(where: { $0.name == options.scenario }) else {
    FileHandle.standardError.write("unknown scenario '\(options.scenario)'; try --list\n".data(using: .utf8)!)
    exit(2)
}

let fps = options.fps.isFinite && options.fps > 0 ? options.fps : 24
let duration = options.duration ?? scenario.duration
let frameCount = max(1, Int((duration * fps).rounded()))
let harness = HostRenderLoopHarness(seed: options.seed,
                                    idleEnabled: scenario.idleEnabled,
                                    ambient: scenario.ambient)

var rows: [Row] = []
var pendingCues = scenario.cues
var scriptTime = 0.0

for frame in 0..<frameCount {
    scriptTime = Double(frame) / fps
    while let next = pendingCues.first, next.at <= scriptTime + 1e-9 {
        next.apply(harness)
        pendingCues.removeFirst()
    }
    let hostTime = scenario.timeWarp(scriptTime)
    let motion = harness.renderFrame(at: hostTime, speech: scenario.speech(scriptTime))
    rows.append(Row(frame: frame, hostTime: hostTime, harness: harness, motion: motion))
}

FileHandle.standardError.write("# scenario \(scenario.name): \(scenario.summary)\n".data(using: .utf8)!)
FileHandle.standardError.write("# \(frameCount) frames at \(Int(fps)) fps, seed 0x\(String(options.seed, radix: 16))\n".data(using: .utf8)!)
emit(rows, format: options.format)
