import Foundation

/// The rules of a Ditto copying a teammate: what a tackle does, when my disguise ends, and which received
/// disguises are drawn.
enum PlazaMimic {
    static let duration: TimeInterval = 300
    static let receiverGrace: TimeInterval = 5

    static func isDitto(speciesID: Int?) -> Bool { speciesID == PlazaDitto.speciesID }

    enum Tackle: Equatable { case disguise(as: String), release, keep }

    /// My tackle on teammate `target` while my plaza Pokémon is a Ditto. In this order: keep when the target is shown disguised
    /// (its own Mac reveals it); release when `mine == target`; keep when the target can't be copied (not in the plaza, or an
    /// egg, like the guest Ditto's rule); else disguise (a switch when `mine` is someone else).
    static func tackle(_ target: String, mine: String?, targetIsDisguised: Bool, targetCopyable: Bool) -> Tackle {
        if targetIsDisguised { return .keep }
        if mine == target { return .release }
        if !targetCopyable { return .keep }
        return .disguise(as: target)
    }

    /// My disguise ends: not a Ditto, the copied member out of the plaza (or turned into an egg), `duration` passed since `since`,
    /// or the wall clock jumped back by more than the grace (else the disguise would last `duration` plus the jump).
    static func isOver(since: Date, now: Date, targetInPlaza: Bool, amDitto: Bool) -> Bool {
        let elapsed = now.timeIntervalSince(since)
        return !amDitto || !targetInPlaza || elapsed < -receiverGrace || elapsed >= duration
    }

    /// Who `m` is drawn as here, nil for themselves. `inPlaza` holds members in the plaza and me.
    static func shownTarget(of m: TeamMemberState, now: Date, inPlaza: Set<String>) -> String? {
        guard isDitto(speciesID: m.character.speciesID), m.inPlaza,
              let target = m.mimicOf, target != m.memberID, inPlaza.contains(target),
              let seen = m.mimicSeenAt, now.timeIntervalSince(seen) < duration + receiverGrace
        else { return nil }
        return target
    }
}

/// A teammate's real look, as a Ditto copies it. Always built from that member's own presence, never from a disguise.
struct PlazaMimicLook: Equatable {
    let memberID: String
    let name: String
    let nameHex: UInt32
    let nature: PokemonNature?
    let subject: CompanionStore.RepresentativeSubject
}
