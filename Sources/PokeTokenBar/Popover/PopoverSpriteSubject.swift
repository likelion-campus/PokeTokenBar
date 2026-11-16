import Foundation

/// Two plaza images are the same picture when they are the same object (what `NSImage`'s equality comes to for the Mac's
/// `SpriteSubject`): the state a view keeps changes only when a different picture arrives.
extension PlazaImage: Equatable {
    static func == (lhs: PlazaImage, rhs: PlazaImage) -> Bool { lhs === rhs }
}

/// What a popover sprite slot shows and which species those pixels belong to: a shared twin of the Mac's `SpriteSubject`
/// (`UI/CompanionView.swift`, upstream-owned, on `NSImage`), stage 7 D8 / D16. The body is the Mac's, line for line,
/// with `NSImage` read as `PlazaImage` (twins.txt); `PopoverTwinEquivalenceTests+Mac` drives both over the Mac's
/// `SpriteSubjectTests` cases. The two rules it keeps: the pixels on screen are the current subject's (an egg after a
/// species drops the species' pixels), and a cancelled load changes nothing. Change the Mac first, then copy here.
struct PopoverSpriteSubject: Equatable {
    var image: PlazaImage?
    var loadedID: Int?
    var loadedShiny = false
    var loadedForm: PokemonForm? = nil
    var loadedBack = false

    func startingLoad(cachedImage: PlazaImage?, for id: Int, shiny: Bool, form: PokemonForm?,
                      back: Bool = false) -> PopoverSpriteSubject {
        PopoverSpriteSubject(image: cachedImage, loadedID: cachedImage == nil ? nil : id,
                      loadedShiny: shiny, loadedForm: PokemonForm.resolved(speciesID: id, form: form),
                      loadedBack: back)
    }

    func becomingEgg(cachedEgg: PlazaImage?) -> PopoverSpriteSubject {
        guard loadedID != nil else { return self }
        return PopoverSpriteSubject(image: cachedEgg, loadedID: nil)
    }

    func applyingLoad(_ image: PlazaImage?, for id: Int, cancelled: Bool,
                      shiny: Bool = false, form: PokemonForm? = nil, back: Bool = false) -> PopoverSpriteSubject? {
        cancelled ? nil : PopoverSpriteSubject(image: image, loadedID: id, loadedShiny: shiny,
                                        loadedForm: PokemonForm.resolved(speciesID: id, form: form),
                                        loadedBack: back)
    }

    func applyingEgg(_ image: PlazaImage?, cancelled: Bool) -> PopoverSpriteSubject? {
        cancelled ? nil : PopoverSpriteSubject(image: image, loadedID: loadedID)
    }
}

/// The frame-selection rules of the Mac's `SpriteView` (statics, twins of `SpriteView.frameTaskID`, `needsReload`,
/// `framesToApply`; bodies verbatim, comments in the Mac file).
enum PopoverSpriteRules {
    static func frameTaskID(speciesID: Int?, shiny: Bool, floor: TimeInterval, animated: Bool = true,
                            form: PokemonForm? = nil, back: Bool = false) -> String {
        let resolved = speciesID.flatMap { PokemonForm.resolved(speciesID: $0, form: form) }
        let id = "\(speciesID.map(String.init) ?? "nil")-\(shiny)-\(floor)-\(animated)-\(resolved?.rawValue ?? "")"
        return back ? id + "-back" : id
    }

    static func framesToApply(_ decoded: [(image: PlazaImage, delay: TimeInterval)],
                              cancelled: Bool) -> [(image: PlazaImage, delay: TimeInterval)] {
        (cancelled || decoded.count < 2) ? [] : decoded
    }

    static func needsReload(loadedID: Int?, loadedShiny: Bool, id: Int, shiny: Bool,
                            loadedForm: PokemonForm? = nil, form: PokemonForm? = nil,
                            loadedBack: Bool = false, back: Bool = false) -> Bool {
        loadedID != id || loadedShiny != shiny || loadedBack != back
            || PokemonForm.resolved(speciesID: id, form: loadedForm)
                != PokemonForm.resolved(speciesID: id, form: form)
    }
}

/// `SpriteFit.size` (`UI/SpriteLoader.swift`): the size an image takes inside a box, aspect kept (a twin: bodies equal).
enum PopoverSpriteFit {
    static func size(for pixelSize: CGSize, box: CGFloat) -> CGSize {
        size(for: pixelSize, width: box, height: box)
    }

    static func size(for pixelSize: CGSize, width: CGFloat, height: CGFloat) -> CGSize {
        guard pixelSize.width > 0, pixelSize.height > 0 else {
            let side = min(width, height)
            return CGSize(width: side, height: side)
        }
        let scale = min(width / pixelSize.width, height / pixelSize.height)
        return CGSize(width: pixelSize.width * scale, height: pixelSize.height * scale)
    }
}
