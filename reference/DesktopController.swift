import AppKit
import AVFoundation
import UniformTypeIdentifiers

final class CharacterWindow: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

final class DesktopController: NSObject, NSWindowDelegate, AVAudioPlayerDelegate {
    let renderer: PortraitRenderer
    let window: CharacterWindow
    let portrait = PortraitView(frame: .zero)
    let defaults: UserDefaults
    private(set) var expression: Expression = .natural
    private var timer: Timer?
    private var blink = BlinkClock()
    private var expressionTransition = ExpressionTransition()
    private var restMouthReturn = RestMouthReturn()
    private var mouth = MouthEnvelope()
    private var hair = HairPhysics()
    private var hairEnabled: Bool
    /// 光影与立体感。默认关闭；关闭时保留本版人物修订的原始输出。
    private var relightEnabled: Bool
    private var player: AVAudioPlayer?
    private var mouthTimeline: MouthTimeline?
    let voiceFollower: VoicePlaybackFollower
    private var voicePollTimer: Timer?
    private var followVoice: Bool
    private var started = ProcessInfo.processInfo.systemUptime
    private var lastTick = ProcessInfo.processInfo.systemUptime
    private var demoStart: Double?
    private var suspended = false
    private var idle: Bool
    private var floating: Bool
    var onMenuChange: (() -> Void)?
    private(set) var renderedFrames = 0
    private(set) var lastFrame = MotionFrame()
    private(set) var peakMouth: Double = 0
    private(set) var peakHair: Double = 0
    private(set) var peakWide: Double = 0
    private(set) var minimumWide: Double = 0
    var usesMouthTimeline: Bool { mouthTimeline != nil || voiceFollower.hasTimeline }

    init(renderer: PortraitRenderer, defaults: UserDefaults = .standard,
         voiceStateURL: URL? = VoicePlaybackFollower.defaultURL) {
        self.renderer = renderer
        self.defaults = defaults
        voiceFollower = VoicePlaybackFollower(stateURL: voiceStateURL)
        followVoice = defaults.object(forKey: "followVoice") as? Bool ?? true
        idle = defaults.object(forKey: "idle") as? Bool ?? true
        floating = defaults.object(forKey: "floating") as? Bool ?? true
        hairEnabled = defaults.object(forKey: "hair") as? Bool ?? true
        relightEnabled = defaults.object(forKey: "relight") as? Bool ?? false
        window = CharacterWindow(contentRect: CGRect(x: 0, y: 0, width: 320, height: 320 / WindowPlacement.aspect),
                                 styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        super.init()
        window.title = "郑植镨"
        window.isReleasedWhenClosed = false
        window.isOpaque = false
        window.backgroundColor = .clear
        window.hasShadow = true
        window.hidesOnDeactivate = false
        window.isFloatingPanel = true
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        window.level = floating ? .floating : .normal
        window.contentView = portrait
        window.delegate = self
        portrait.menuProvider = { [weak self] in self?.makeMenu() ?? NSMenu() }
        portrait.onHide = { [weak self] in self?.hide() }
        portrait.onResize = { [weak self] in self?.resize(to: $0) }
        portrait.onSave = { [weak self] in self?.savePlacement() }
        portrait.onAudioDrop = { [weak self] in self?.playAudio($0) }
        restorePlacement()
        if relightEnabled { applyRelight() }
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(willSleep), name: NSWorkspace.willSleepNotification, object: nil)
        NSWorkspace.shared.notificationCenter.addObserver(self, selector: #selector(didWake), name: NSWorkspace.didWakeNotification, object: nil)
        NotificationCenter.default.addObserver(self, selector: #selector(screensChanged), name: NSApplication.didChangeScreenParametersNotification, object: nil)
    }
    deinit { timer?.invalidate(); voicePollTimer?.invalidate(); NotificationCenter.default.removeObserver(self); NSWorkspace.shared.notificationCenter.removeObserver(self) }
    var screens: [CGRect] { NSScreen.screens.map(\.visibleFrame) }
    var elapsed: Double { ProcessInfo.processInfo.systemUptime - started }
    var isRunningAnimation: Bool { timer != nil }
    var isAudioPlaying: Bool { player?.isPlaying == true }

    func show() {
        let wasVisible = window.isVisible
        window.setFrame(WindowPlacement.fit(window.frame, in: screens), display: true)
        window.orderFrontRegardless()
        suspended = false
        if !wasVisible { blink.reset(at: elapsed); hair.reset() }
        lastTick = ProcessInfo.processInfo.systemUptime
        renderFrame()
        updateTimer()
        onMenuChange?()
    }
    func hide() {
        savePlacement()
        window.orderOut(nil)
        voicePollTimer?.invalidate(); voicePollTimer = nil; voiceFollower.reset()
        stopAudio()
        timer?.invalidate(); timer = nil
        onMenuChange?()
    }
    func resize(to width: CGFloat) {
        let old = window.frame
        let proposed = CGRect(x: old.minX, y: old.maxY - width / WindowPlacement.aspect, width: width, height: width / WindowPlacement.aspect)
        window.setFrame(WindowPlacement.fit(proposed, in: screens), display: true)
        renderFrame(); savePlacement()
    }
    func savePlacement() {
        defaults.set(NSStringFromRect(window.frame), forKey: "frame")
    }
    private func restorePlacement() {
        let screen = NSScreen.main?.visibleFrame ?? CGRect(x: 0, y: 0, width: 1440, height: 900)
        let initial = CGRect(x: screen.maxX - 344, y: screen.minY + 36, width: 320, height: 320 / WindowPlacement.aspect)
        let proposed = defaults.string(forKey: "frame").map(NSRectFromString) ?? initial
        window.setFrame(WindowPlacement.fit(proposed, in: screens), display: true)
    }
    func windowDidMove(_ notification: Notification) { savePlacement() }
    func windowWillClose(_ notification: Notification) { voicePollTimer?.invalidate(); voicePollTimer = nil; voiceFollower.reset(); timer?.invalidate(); timer = nil; stopAudio() }
    @objc private func screensChanged() {
        window.setFrame(WindowPlacement.fit(window.frame, in: screens), display: true); savePlacement()
    }
    @objc private func willSleep() { suspended = true; timer?.invalidate(); timer = nil; voicePollTimer?.invalidate(); voicePollTimer = nil; voiceFollower.reset(); stopAudio() }
    @objc private func didWake() { suspended = false; if window.isVisible { blink.reset(at: elapsed); updateTimer() } }
    private func updateTimer() {
        let follow = window.isVisible && !suspended && followVoice && voiceFollower.stateURL != nil
        if follow && voicePollTimer == nil {
            let poll = Timer(timeInterval: 0.08, repeats: true) { [weak self] _ in
                guard let self else { return }
                let before = self.voiceFollower.activeID
                self.voiceFollower.refresh(now: ProcessInfo.processInfo.systemUptime)
                if let current = self.voiceFollower.activeID, current != before {
                    self.player?.stop(); self.player = nil; self.mouthTimeline = nil; self.demoStart = nil; self.mouth.reset()
                }
                if before != nil && self.voiceFollower.activeID == nil { self.mouth.reset() }
                self.updateTimer()
                if before != self.voiceFollower.activeID { self.renderFrame() }
            }
            RunLoop.main.add(poll, forMode: .common); voicePollTimer = poll
        } else if !follow { voicePollTimer?.invalidate(); voicePollTimer = nil }
        let needed = window.isVisible && !suspended && (idle || expressionTransition.isActive || restMouthReturn.isActive || player?.isPlaying == true || demoStart != nil || voiceFollower.activeID != nil)
        if needed && timer == nil {
            let timer = Timer(timeInterval: 1.0 / 24.0, repeats: true) { [weak self] _ in self?.renderFrame() }
            timer.tolerance = 0.005
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else if !needed { timer?.invalidate(); timer = nil }
    }
    func renderFrame(forced: MotionFrame? = nil) {
        let now = ProcessInfo.processInfo.systemUptime
        let delta = now - lastTick; lastTick = now
        var db: Float?
        if let player, player.isPlaying {
            player.updateMeters()
            db = (0..<player.numberOfChannels).map { player.averagePower(forChannel: $0) }.max()
        }
        let wasFollowing = voiceFollower.activeID != nil
        let followed = followVoice ? voiceFollower.sample(now: now) : nil
        if wasFollowing && voiceFollower.activeID == nil && player?.isPlaying != true { mouth.reset() }
        if player?.isPlaying != true, let followed { db = followed.decibels }
        var openness = mouth.update(decibels: db, delta: delta)
        var wideness = 0.0
        let scheduled = player?.isPlaying == true ? mouthTimeline?.pose(at: player!.currentTime) : followed?.pose
        if let scheduled {
            openness = scheduled.open; wideness = scheduled.wide
            if let db, db < -55 { openness = 0; wideness = 0 }
        }
        if let demo = demoStart {
            let t = elapsed - demo
            if t > SpeechDemo.duration { demoStart = nil; updateTimer() }
            else {
                let pose = SpeechDemo.pose(at: t)
                openness = pose.open; wideness = pose.wide
            }
        }
        let reduced = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        let hairPose: HairPose
        if idle && hairEnabled && !reduced { hairPose = hair.advance(delta: delta) }
        else { hair.reset(); hairPose = HairPose() }
        peakHair = max(peakHair, hairPose.maximumDisplacement)
        let wasTransitioning = expressionTransition.isActive
        var expressionPose = expressionTransition.sample(at: elapsed)
        let speechActive = player?.isPlaying == true || voiceFollower.activeID != nil || demoStart != nil
        let wasReturning = restMouthReturn.isActive
        expressionPose.parted *= restMouthReturn.amount(speaking: speechActive, at: elapsed)
        let frame = forced ?? MotionFrame(time: elapsed, blink: idle ? blink.value(at: elapsed) : 0,
                                          mouth: openness, mouthWide: wideness, movement: idle && !reduced ? 1 : 0, expression: expression, hair: hairPose, expressionPose: expressionPose, speechActive: speechActive)
        let width = Int(min(960, max(300, portrait.bounds.width * (window.backingScaleFactor))))
        if let cg = renderer.render(frame, width: width) { portrait.display(cg); renderedFrames += 1; lastFrame = frame; peakMouth = max(peakMouth, frame.mouth); peakWide = max(peakWide, frame.mouthWide); minimumWide = min(minimumWide, frame.mouthWide) }
        if (wasTransitioning && !expressionTransition.isActive) || wasReturning != restMouthReturn.isActive { updateTimer() }
    }
    func playAudio(_ url: URL, volume: Float = 1) {
        do {
            let newPlayer = try AVAudioPlayer(contentsOf: url)
            player?.stop(); demoStart = nil; mouth.reset()
            player = newPlayer; newPlayer.delegate = self; newPlayer.volume = volume
            mouthTimeline = MouthTimeline.load(for: url, duration: newPlayer.duration)
            peakMouth = 0; peakWide = 0; minimumWide = 0
            if expression == .resting { setExpression(.natural) }
            newPlayer.isMeteringEnabled = true
            newPlayer.prepareToPlay()
            show()
            guard newPlayer.play() else { throw NSError(domain: "Audio", code: 1, userInfo: [NSLocalizedDescriptionKey: "无法播放这个音频文件"]) }
            updateTimer(); onMenuChange?()
        } catch {
            player = nil; mouthTimeline = nil; mouth.reset(); updateTimer()
            let alert = NSAlert(error: error); NSApp.activate(ignoringOtherApps: true); alert.runModal()
        }
    }
    func stopAudio() { player?.stop(); player = nil; mouthTimeline = nil; demoStart = nil; mouth.reset(); updateTimer(); onMenuChange?() }
    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) { stopAudio(); renderFrame() }
    func audioPlayerDecodeErrorDidOccur(_ player: AVAudioPlayer, error: Error?) { stopAudio(); renderFrame() }
    @objc private func chooseAudio() {
        let panel = NSOpenPanel(); panel.allowedContentTypes = [.audio]; panel.allowsMultipleSelection = false
        panel.message = "选择语音；有同名口型文件时跟随发音，否则跟随音量"
        NSApp.activate(ignoringOtherApps: true)
        if panel.runModal() == .OK, let url = panel.url { playAudio(url) }
    }
    @objc private func stopSpeech() { stopAudio(); renderFrame() }
    @objc func toggleVisible() { window.isVisible ? hide() : show() }
    @objc private func toggleIdle() { idle.toggle(); defaults.set(idle, forKey: "idle"); blink.reset(at: elapsed); renderFrame(); updateTimer() }
    @objc private func toggleHair() { hairEnabled.toggle(); defaults.set(hairEnabled, forKey: "hair"); hair.reset(); renderFrame() }

    /// 第一次打开要烘焙一次贴图,约 0.4 秒,只发生一次;之后开关是即时的。
    private func applyRelight() {
        if relightEnabled {
            var settings = RelightSettings()
            settings.strength = 1.0
            renderer.relightSettings = settings
            if !renderer.relightReady { relightEnabled = false; renderer.relightSettings = .off }
        } else {
            renderer.relightSettings = .off
        }
    }
    @objc private func toggleRelight() {
        relightEnabled.toggle()
        applyRelight()
        defaults.set(relightEnabled, forKey: "relight")
        renderFrame(); onMenuChange?()
    }
    @objc private func toggleFollowVoice() { followVoice.toggle(); defaults.set(followVoice, forKey: "followVoice"); voiceFollower.reset(); mouth.reset(); updateTimer(); renderFrame() }
    @objc private func toggleFloating() { floating.toggle(); defaults.set(floating, forKey: "floating"); window.level = floating ? .floating : .normal }
    @objc private func changeSize(_ item: NSMenuItem) { resize(to: CGFloat(item.tag)) }
    @objc private func resetPosition() {
        defaults.removeObject(forKey: "frame"); restorePlacement(); savePlacement(); show()
    }
    @objc private func chooseExpression(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String, let expression = Expression(rawValue: raw) else { return }
        setExpression(expression)
    }
    func setExpression(_ expression: Expression) {
        self.expression = expression
        expressionTransition.set(expression, at: elapsed)
        renderFrame(); updateTimer(); onMenuChange?()
    }
    @objc func demoSpeech() { show(); player?.stop(); player = nil; mouthTimeline = nil; mouth.reset(); peakMouth = 0; demoStart = elapsed; setExpression(.natural); updateTimer() }
    @objc private func quit() { savePlacement(); NSApp.terminate(nil) }

    func makeMenu() -> NSMenu {
        let menu = NSMenu()
        @discardableResult func add(_ title: String, _ action: Selector, checked: Bool? = nil) -> NSMenuItem {
            let item = NSMenuItem(title: title, action: action, keyEquivalent: ""); item.target = self
            if let checked { item.state = checked ? .on : .off }
            menu.addItem(item); return item
        }
        add(window.isVisible ? "隐藏郑植镨" : "显示郑植镨", #selector(toggleVisible))
        add("浮在其他窗口上方", #selector(toggleFloating), checked: floating)
        add("自然待机动作", #selector(toggleIdle), checked: idle)
        add("头发轻柔摆动", #selector(toggleHair), checked: hairEnabled)
        add("光影与立体感", #selector(toggleRelight), checked: relightEnabled)
        add("跟随现有语音", #selector(toggleFollowVoice), checked: followVoice)
        menu.addItem(.separator())
        let expressions = NSMenu()
        for value in Expression.allCases {
            if (value == .smile || value == .softSmile) && !renderer.assetNames.contains("smile") { continue }
            if value == .resting && !renderer.assetNames.contains("blink-closed") { continue }
            if value == .pressedLips && !renderer.assetNames.contains("pressed-lips") { continue }
            if value == .partedLips && !renderer.assetNames.contains("mouth-open") { continue }
            let item = NSMenuItem(title: value.title, action: #selector(chooseExpression(_:)), keyEquivalent: "")
            item.representedObject = value.rawValue; item.target = self; item.state = expression == value ? .on : .off; expressions.addItem(item)
        }
        let expressionItem = NSMenuItem(title: "表情", action: nil, keyEquivalent: ""); expressionItem.submenu = expressions; menu.addItem(expressionItem)
        add("试一下说话动作（无声）", #selector(demoSpeech))
        add("播放语音文件…", #selector(chooseAudio))
        if player != nil || demoStart != nil { add("停止说话", #selector(stopSpeech)) }
        menu.addItem(.separator())
        let sizes = NSMenu()
        for (title, width) in [("小", 240), ("适中", 320), ("大", 420)] {
            let item = NSMenuItem(title: title, action: #selector(changeSize(_:)), keyEquivalent: "")
            item.tag = width; item.target = self; sizes.addItem(item)
        }
        let sizeItem = NSMenuItem(title: "人物大小", action: nil, keyEquivalent: ""); sizeItem.submenu = sizes; menu.addItem(sizeItem)
        add("重置位置", #selector(resetPosition))
        menu.addItem(.separator())
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "开发版"
        let info = NSMenuItem(title: "人物与光影版 · \(version)", action: nil, keyEquivalent: "")
        info.isEnabled = false; menu.addItem(info)
        add("退出", #selector(quit))
        return menu
    }
}
