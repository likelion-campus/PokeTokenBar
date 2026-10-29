import Foundation

enum TeamEventFactory {
    static func make(_ e: CompanionTeamEvent, authorID: String, nickname: String, now: Date,
                     hasOnlinePeers: Bool, calendar: Calendar = .current,
                     id: String = UUID().uuidString) -> TeamEvent {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.timeZone = calendar.timeZone
        f.dateFormat = "yyyy-MM-dd"
        return TeamEvent(id: id, authorID: authorID, authorNickname: nickname, kind: e.kind,
                         speciesID: e.speciesID, fromSpeciesID: e.fromSpeciesID,
                         speciesName: e.speciesName, fromSpeciesName: e.fromSpeciesName,
                         form: e.form, isShiny: e.isShiny, nature: e.nature, rarity: e.rarity,
                         day: f.string(from: now), occurredAt: hasOnlinePeers ? now : nil)
    }
}
