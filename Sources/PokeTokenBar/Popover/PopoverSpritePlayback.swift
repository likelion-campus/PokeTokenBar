import Foundation

typealias PopoverSpriteFrames = [(image: PlazaImage, delay: TimeInterval)]

/// What the popover keeps of decoded sprites while it is open: GIF frame sets (at most `frameSets`, oldest out first) and
/// stills (at most `stills`), and the egg. `release()` empties it (the popover closed).
@MainActor final class PopoverSpriteMemory {
    static let frameSets = 4
    static let stills = 8
    private var frames: [String: PopoverSpriteFrames] = [:]
    private var frameOrder: [String] = []
    private var stills: [String: PlazaImage] = [:]
    private var stillOrder: [String] = []
    private(set) var egg: PlazaImage?

    var frameSetCount: Int { frames.count }
    var stillCount: Int { stills.count }

    func frames(for key: String) -> PopoverSpriteFrames { frames[key] ?? [] }
    func keepFrames(_ value: PopoverSpriteFrames, for key: String) {
        if frames[key] == nil { frameOrder.append(key) }
        frames[key] = value
        while frameOrder.count > Self.frameSets { frames.removeValue(forKey: frameOrder.removeFirst()) }
    }

    func still(for key: String) -> PlazaImage? { stills[key] }
    func keepStill(_ value: PlazaImage, for key: String) {
        if stills[key] == nil { stillOrder.append(key) }
        stills[key] = value
        while stillOrder.count > Self.stills { stills.removeValue(forKey: stillOrder.removeFirst()) }
    }

    func keepEgg(_ image: PlazaImage) { egg = image }

    func release() {
        frames = [:]; frameOrder = []; stills = [:]; stillOrder = []; egg = nil
    }
}

/// One sprite slot's state: the Mac `SpriteView`'s `.task(id:)` body as a state machine over `PlazaSpriteFetching`
/// (shared by both systems, tested on both). A subject change cancels the load in flight and bumps `generation`; a load
/// that finishes after that (or after `release()`) changes nothing (the Mac's `Task.isCancelled` guard, `PopoverSpriteSubject`
/// carries the rules). Frame times: the GIF's own delays; the bob (a still sprite) follows the Mac's eased 0.9 s swing up
/// 3 DIP and back, one step per device pixel (`bobSteps`; stage 7 Task 9).
@MainActor final class PopoverSpriteModel {
    static let bobPeriod: TimeInterval = 0.9
    /// Due times closer than this tick together (floating-point sums of delays differ by a few ulps).
    static let slack: TimeInterval = 0.0005

    private let fetcher: any PlazaSpriteFetching
    private let memory: PopoverSpriteMemory
    private let now: () -> Date
    private var task: Task<Void, Never>?

    private(set) var subject = PopoverSpriteSubject(image: nil, loadedID: nil)
    private(set) var frames: PopoverSpriteFrames = []
    private(set) var frameIndex = 0
    private(set) var generation = 0
    private(set) var taskID: String?
    private(set) var key: PlazaSpriteSubjectKey?
    private(set) var animated = false
    // --- stage 7 Task 22: the floating pet's frame cap (begin) ---
    /// The shortest frame a GIF plays at (`UsageStore.AnimationQuality.frameFloor`): its frames are decimated to it
    /// (`PopoverSpriteFrameCap`, the Mac's `GIFDecoder.capFrameRate`); 0 plays the GIF's own delays (the popover). Part of the
    /// task identity, as the Mac's `SpriteView.frameTaskID`: a new floor decodes again.
    var frameFloor: TimeInterval = 0
    /// A load is under way for the current subject (the floating pet keeps its last picture meanwhile instead of the 🥚).
    private(set) var isLoading = false
    // --- stage 7 Task 22 (end) ---
    // --- the GIF asked again until it comes (fix/windows-pet-still) (begin) ---
    /// The Mac's `SpriteLoader.recoveringAnimationFrames`: a species that has a GIF (`PokemonAssets.hasAnimatedSprite`) but got
    /// none (its first download failed: no file yet, the network down at sign-in) keeps its still and asks again `firstRetry`
    /// later, doubling to `maxRetry`, with no attempt limit, until the frames come or the subject changes (the task is
    /// cancelled). A species without a GIF stops at its still. The wait is a seam (tests pass their own).
    static let firstRetry: TimeInterval = 2, maxRetry: TimeInterval = 30
    var waitBeforeRetry: @Sendable (TimeInterval) async throws -> Void = { try await Task.sleep(nanoseconds: UInt64($0 * 1_000_000_000)) }
    /// How many times the current subject's GIF was asked for (1 when it came at once).
    private(set) var gifAsks = 0
    // --- (end) ---
    // --- stage 7 Task 9: the bob in device-pixel steps of the Mac's `.easeInOut(duration: 0.9).repeatForever` (begin) ---
    /// The bob's travel in DIP (the Mac's `.offset(y: -3)`).
    static let bobTravel: CGFloat = 3
    /// The bob's height now, 0…`bobSteps` steps of `bobTravel` (0: at rest).
    private(set) var bobLevel = 0
    private var bobSwing = PopoverEasedSwing(duration: bobPeriod, steps: 3)
    private var bobStart: Date?
    /// The steps the bob is drawn in: the host's device pixels for `bobTravel` (3 at 100 %). A change restarts the bob.
    var bobSteps: Int {
        get { bobSwing.steps }
        set {
            guard max(1, newValue) != bobSwing.steps else { return }
            bobSwing = PopoverEasedSwing(duration: Self.bobPeriod, steps: newValue)
            bobDue = nil
            bobLevel = 0
            reschedule()
        }
    }
    /// The bob's offset in DIP (negative: up).
    var bobOffset: CGFloat { -Self.bobTravel * CGFloat(bobLevel) / CGFloat(bobSwing.steps) }
    var bobUp: Bool { bobLevel > 0 }
    // --- stage 7 Task 9 (end) ---
    private var bobs = false
    private var playing = false
    private var frameDue: Date?
    private var bobDue: Date?
    private(set) var released = false
    /// The picture the slot shows changed (a load finished).
    var onChange: (() -> Void)?

    init(fetcher: any PlazaSpriteFetching, memory: PopoverSpriteMemory, now: @escaping () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.memory = memory
        self.now = now
    }

    /// The current picture: the GIF's frame, else the still. nil: the 🥚 glyph.
    var current: PlazaImage? { frames.isEmpty ? subject.image : frames[frameIndex % frames.count].image }
    var isAnimating: Bool { frames.count > 1 }
    /// The earliest moment something about the picture changes by itself (nil: nothing does).
    var nextDue: Date? { [frameDue, bobDue].compactMap { $0 }.min() }

    private func stillKey(_ k: PlazaSpriteSubjectKey, form: PokemonForm?) -> String {
        PopoverSpriteRules.frameTaskID(speciesID: k.speciesID, shiny: k.shiny, floor: 0, animated: false, form: form, back: k.back)
    }

    /// Shows `slot`'s subject. Same task identity (species, shiny, floor, animated, form, back): nothing happens.
    func show(_ subjectKey: PlazaSpriteSubjectKey?, animated: Bool, bob: Bool) {
        guard !released else { return }
        bobs = bob
        guard let k = subjectKey else {
            cancel()
            taskID = nil; key = nil; self.animated = false
            frames = []; frameIndex = 0
            subject = PopoverSpriteSubject(image: nil, loadedID: nil)
            reschedule()
            return
        }
        let form = k.speciesID.flatMap { PokemonForm.resolved(speciesID: $0, form: k.form) }
        let id = PopoverSpriteRules.frameTaskID(speciesID: k.speciesID, shiny: k.shiny, floor: frameFloor, animated: animated, form: form, back: k.back)  // floor: stage 7 Task 22
        guard id != taskID else { reschedule(); return }
        cancel()
        taskID = id
        key = k
        self.animated = animated
        let g = generation
        // Animated frames are reset on every change (no afterimage of the previous subject).
        let cachedFrames = animated && k.speciesID != nil ? memory.frames(for: id) : []
        frames = cachedFrames.count > 1 || (frameFloor > 0 && !cachedFrames.isEmpty) ? cachedFrames : []  // a capped set may be one frame (stage 7 Task 22)
        frameIndex = 0
        frameDue = nil
        guard let species = k.speciesID else {
            apply(subject.becomingEgg(cachedEgg: memory.egg))
            if subject.image == nil {
                launch { [self] in
                    let egg = await fetcher.egg()
                    if let egg { memory.keepEgg(egg) }
                    if let next = subject.applyingEgg(egg, cancelled: Task.isCancelled || generation != g) { apply(next) }
                    loaded()
                }
            }
            reschedule()
            return
        }
        if PopoverSpriteRules.needsReload(loadedID: subject.loadedID, loadedShiny: subject.loadedShiny, id: species, shiny: k.shiny,
                                          loadedForm: subject.loadedForm, form: form, loadedBack: subject.loadedBack, back: k.back) {
            apply(subject.startingLoad(cachedImage: memory.still(for: stillKey(k, form: form)), for: species, shiny: k.shiny,
                                       form: form, back: k.back))
        }
        if animated && frames.isEmpty {
            gifAsks = 0
            launch { [self] in
                var retry = Self.firstRetry, showedStill = false
                while true {
                    var decoded = await fetcher.animated(speciesID: species, shiny: k.shiny, form: form, back: k.back)
                    if decoded.count < 2, k.back {   // a missing back sprite: the front stands in
                        decoded = await fetcher.animated(speciesID: species, shiny: k.shiny, form: form, back: false)
                    }
                    guard !Task.isCancelled, generation == g else { return }
                    gifAsks += 1
                    let ready = PopoverSpriteFrameCap.capFrameRate(PopoverSpriteRules.framesToApply(decoded, cancelled: false), floor: frameFloor)  // the cap: stage 7 Task 22
                    if !ready.isEmpty {
                        memory.keepFrames(ready, for: id)
                        frames = ready
                        frameIndex = 0
                        loaded()
                        return
                    }
                    // No GIF (yet): the still once, then asked again (fix/windows-pet-still: the Mac's recovering loop).
                    if !showedStill {
                        await loadStill(species, k, form, g)
                        showedStill = true
                        loaded()
                    }
                    guard PokemonAssets.hasAnimatedSprite(speciesID: species), !Task.isCancelled, generation == g else { return }
                    do { try await waitBeforeRetry(retry) } catch { return }
                    guard !Task.isCancelled, generation == g else { return }
                    retry = min(retry * 2, Self.maxRetry)
                }
            }
        } else if frames.isEmpty {
            launch { [self] in
                await loadStill(species, k, form, g)
                loaded()
            }
        }
        reschedule()
    }

    private func loadStill(_ species: Int, _ k: PlazaSpriteSubjectKey, _ form: PokemonForm?, _ g: Int) async {
        var image = await fetcher.still(speciesID: species, shiny: k.shiny, form: form, back: k.back)
        if image == nil, k.back { image = await fetcher.still(speciesID: species, shiny: k.shiny, form: form, back: false) }
        if let image { memory.keepStill(image, for: stillKey(k, form: form)) }
        if let next = subject.applyingLoad(image, for: species, cancelled: Task.isCancelled || generation != g,
                                           shiny: k.shiny, form: form, back: k.back) { apply(next) }
    }

    private func launch(_ body: @escaping @MainActor () async -> Void) {
        isLoading = true  // stage 7 Task 22
        task = Task { @MainActor in await body() }
    }

    private func cancel() {
        task?.cancel()
        task = nil
        isLoading = false  // stage 7 Task 22
        generation += 1
    }

    private func apply(_ next: PopoverSpriteSubject) {
        guard next != subject else { return }
        subject = next
    }

    private func loaded() {
        isLoading = false  // stage 7 Task 22
        guard !released else { return }
        reschedule()
        onChange?()
    }

    /// Whether the clock runs for this slot (visible, animation on). Stopped: no due times.
    func setPlaying(_ on: Bool) {
        guard on != playing else { return }
        playing = on
        reschedule()
    }

    /// Arms or clears the due times for the present state: a GIF's next frame, or a still sprite's bob.
    private func reschedule() {
        guard playing, !released else { frameDue = nil; bobDue = nil; if !playing { bobLevel = 0 }; return }
        if isAnimating { if frameDue == nil { frameDue = now().addingTimeInterval(frames[frameIndex % frames.count].delay) } } else { frameDue = nil }
        if bobs && !isAnimating && key != nil {
            if bobDue == nil {
                let start = now()
                bobStart = start
                bobLevel = 0
                bobDue = start.addingTimeInterval(bobSwing.nextChange(after: 0))
            }
        } else {
            bobDue = nil
            bobLevel = 0
        }
    }

    /// Advances what is due at `time`; true when the picture or its offset changed (the slot needs painting).
    func tick(at time: Date) -> Bool {
        guard !released else { return false }
        var changed = false
        if let due = frameDue, isAnimating, time.addingTimeInterval(Self.slack) >= due {
            frameIndex = (frameIndex + 1) % frames.count
            var next = due.addingTimeInterval(frames[frameIndex].delay)
            if next <= time { next = time.addingTimeInterval(frames[frameIndex].delay) }   // behind: no burst of catch-up frames
            frameDue = next
            changed = true
        }
        if let due = bobDue, let start = bobStart, time.addingTimeInterval(Self.slack) >= due {
            // A tick a hair early counts as at its due; a late one is read at its own time (no catch-up steps). The next due
            // is always later than both, so the clock moves on.
            let at = max(time, due).timeIntervalSince(start)
            let level = bobSwing.level(at: at)
            if level != bobLevel { bobLevel = level; changed = true }
            bobDue = start.addingTimeInterval(bobSwing.nextChange(after: at))
        }
        return changed
    }

    /// The popover closed or the view is gone: cancels the load, drops the frames and the cache; nothing paints after.
    func release() {
        cancel()
        released = true
        frames = []
        subject = PopoverSpriteSubject(image: nil, loadedID: nil)
        frameDue = nil
        bobDue = nil
        onChange = nil
    }
}

/// The slots of one drawn view, one model each, one clock. `update(slots:)` after every render; `isActive` (the view is
/// shown, animation is on) arms the clock for the earliest due; a tick advances what is due and reports the slots to
/// repaint. Nothing is armed while inactive, with no animated or bobbing slot, or after `release()`.
@MainActor final class PopoverSpritePlayback {
    let clock: PopoverAnimationClock
    let memory = PopoverSpriteMemory()
    private let fetcher: any PlazaSpriteFetching
    private let now: () -> Date
    private(set) var models: [PopoverSpriteModel] = []
    private var slots: [SpriteSlot] = []
    private(set) var ticks = 0
    private(set) var released = false
    /// Animation allowed (reduced motion, the app's setting): off shows the first picture only, and loads the still.
    var animationsEnabled = true { didSet { if oldValue != animationsEnabled { update(slots: slots) } } }
    /// The view is shown on screen.
    var isActive = false { didSet { if oldValue != isActive { applyActive() } } }
    /// A slot's picture changed: its index.
    var onInvalidate: ((Int) -> Void)?
    // --- stage 7 Task 9 (begin) ---
    /// The steps a bob is drawn in (`PopoverSpriteModel.bobSteps`): the host's device pixels for 3 DIP.
    var bobSteps = 3 {
        didSet {
            guard oldValue != bobSteps else { return }
            for model in models { model.bobSteps = bobSteps }
            rearm()
        }
    }
    // --- stage 7 Task 9 (end) ---
    // --- stage 7 Task 22: the floating pet's frame cap (begin) ---
    /// Every slot's `PopoverSpriteModel.frameFloor` (the pet's animation quality); a change loads the slots again.
    var frameFloor: TimeInterval = 0 { didSet { if oldValue != frameFloor { update(slots: slots) } } }
    // --- stage 7 Task 22 (end) ---
    /// The wait before a GIF that did not come is asked for again (`PopoverSpriteModel.waitBeforeRetry`; tests pass their own).
    var waitBeforeRetry: (@Sendable (TimeInterval) async throws -> Void)?   // fix/windows-pet-still

    init(fetcher: any PlazaSpriteFetching, clock: PopoverAnimationClock = PopoverAnimationClock(), now: @escaping () -> Date = { Date() }) {
        self.fetcher = fetcher
        self.clock = clock
        self.now = now
        clock.onTick = { [weak self] in self?.tick() }
    }

    func update(slots new: [SpriteSlot]) {
        guard !released else { return }
        slots = new
        while models.count > new.count { models.removeLast().release() }
        while models.count < new.count {
            let index = models.count
            let model = PopoverSpriteModel(fetcher: fetcher, memory: memory, now: now)
            if let waitBeforeRetry { model.waitBeforeRetry = waitBeforeRetry }   // fix/windows-pet-still
            model.bobSteps = bobSteps  // stage 7 Task 9
            model.frameFloor = frameFloor  // stage 7 Task 22
            model.onChange = { [weak self] in self?.modelChanged(index) }
            models.append(model)
        }
        for (model, slot) in zip(models, new) {
            model.frameFloor = frameFloor  // stage 7 Task 22
            model.show(slot.subject, animated: slot.animated && animationsEnabled, bob: slot.bob && animationsEnabled)
            model.setPlaying(isActive && animationsEnabled)
        }
        rearm()
    }

    private func applyActive() {
        for model in models { model.setPlaying(isActive && animationsEnabled) }
        rearm()
    }

    private func modelChanged(_ index: Int) {
        guard !released else { return }
        models[index].setPlaying(isActive && animationsEnabled)
        rearm()
        onInvalidate?(index)
    }

    /// Asked at every tick: false (the view is hidden or scrolled out meanwhile) makes the playback inactive instead.
    var shouldTick: (() -> Bool)?

    private func tick() {
        guard !released else { return }
        if let shouldTick, !shouldTick() { isActive = false; return }
        ticks += 1
        let time = now()
        for (i, model) in models.enumerated() where model.tick(at: time) { onInvalidate?(i) }
        rearm()
    }

    private func rearm() {
        clock.setDue(isActive && animationsEnabled && !released ? models.compactMap(\.nextDue).min() : nil)
    }

    /// Closes: no timer, loads cancelled, frames and cache freed.
    func release() {
        guard !released else { return }
        released = true
        clock.setDue(nil)
        clock.onTick = nil
        for model in models { model.release() }
        models = []
        memory.release()
        onInvalidate = nil
    }
}
