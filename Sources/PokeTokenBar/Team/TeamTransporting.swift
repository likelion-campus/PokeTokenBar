import Foundation

@MainActor
protocol TeamTransporting: AnyObject {
    var onPeerConnected: ((TeamPeerID, _ initiatedByMe: Bool) -> Void)? { get set }
    var onPeerDisconnected: ((TeamPeerID) -> Void)? { get set }
    var onMessage: ((TeamPeerID, TeamMessage) -> Void)? { get set }
    /// A frame could not be decoded. The transport drops the link and holds off dialing its endpoint.
    var onPeerBadFrame: ((TeamPeerID) -> Void)? { get set }

    func start(code: TeamCode)
    /// Silent: no callbacks after this returns.
    func stop()
    func send(_ m: TeamMessage, to peer: TeamPeerID)
    /// Owner-initiated and silent (no `onPeerDisconnected`). With `kept`, the endpoint of `peer` is not
    /// dialed again while `kept` stays alive. Unknown peers are ignored.
    func disconnect(_ peer: TeamPeerID, coveredBy kept: TeamPeerID?)
    /// Like `disconnect`, but the owner does not want this peer: its endpoint is not dialed again for 5 minutes.
    func refuse(_ peer: TeamPeerID)
}
