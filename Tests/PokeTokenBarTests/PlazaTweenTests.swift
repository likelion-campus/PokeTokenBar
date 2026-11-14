import XCTest
@testable import PokeTokenBar

/// The expected values are SpriteKit's, read from `SKAction`s under `SKRenderer` at t = 1000 + frame/60 (Task 7 probes;
/// `PlazaTweenOracleTests` compares live). Frames advance as `PlazaScene.update` does: dt = this time - the last one.
@MainActor
final class PlazaTweenTests: XCTestCase {
    private func time(_ frame: Int) -> TimeInterval { 1000 + Double(frame) / 60 }

    /// Runs frames 0...last; `before(frame)` runs ahead of that frame's step (a key handler between frames).
    private func drive(_ tweens: PlazaTweens, through last: Int, before: (Int) -> Void = { _ in }, after: (Int) -> Void) {
        for f in 0...last {
            before(f)
            tweens.advance(by: f == 0 ? 0 : time(f) - time(f - 1))
            after(f)
        }
    }

    private func node(in root: PlazaNode, x: CGFloat = 100.5, y: CGFloat = 50.3) -> PlazaSprite {
        let n = PlazaSprite(color: .white, size: CGSize(width: 10, height: 10))
        n.position = CGPoint(x: x, y: y)
        root.addChild(n)
        return n
    }

    func testTweenFirstStepIsProgressZero() async {
        let root = PlazaNode()
        let n = node(in: root)
        let tweens = PlazaTweens()
        var seen: [Int: (CGFloat, CGFloat, CGFloat, Bool)] = [:]
        drive(tweens, through: 24, before: { f in
            if f == 2 {
                tweens.run(.sequence([.group([.moveBy(dx: 10, dy: 3, duration: 0.35), .fadeOut(duration: 0.35)]), .removeFromParent]), on: n)
            }
        }, after: { f in seen[f] = (n.position.x, n.position.y, n.alpha, n.parent != nil) })
        XCTAssertEqual(seen[2]?.0, 100.5, "the first step is at progress 0, whatever dt is")
        XCTAssertEqual(seen[2]?.1, 50.299999237060547)
        XCTAssertEqual(seen[2]?.2, 1)
        XCTAssertEqual(seen[3]?.0, 100.97618865966797)
        XCTAssertEqual(seen[3]?.1, 50.442855834960938)
        XCTAssertEqual(seen[3]?.2, 0.9523809552192688)
        XCTAssertEqual(seen[4]?.0, 101.45237731933594)
        XCTAssertEqual(seen[22]?.0, 110.02377319335938)
        XCTAssertEqual(seen[22]?.1, 53.157131195068359)
        XCTAssertEqual(seen[22]?.2, 0.047618985176086426)
        XCTAssertEqual(seen[22]?.3, true)
        XCTAssertEqual(seen[23]?.2, 0)
        XCTAssertEqual(seen[23]?.3, false, "removed in the frame the group ends")
        XCTAssertEqual(tweens.count, 0)
    }

    /// The tackle impact: the fade starts in the frame the wait ends, with the time left over.
    func testSequenceCarriesOverInTheSameFrame() async {
        let root = PlazaNode()
        let n = node(in: root)
        n.setScale(0.6)
        let tweens = PlazaTweens()
        var seen: [Int: (CGFloat, CGFloat, Bool)] = [:]
        drive(tweens, through: 23, before: { f in
            if f == 1 {
                tweens.run(.sequence([.group([.scaleTo(1.4, duration: 0.14), .sequence([.wait(0.12), .fadeOut(duration: 0.22)])]),
                                      .removeFromParent]), on: n)
            }
        }, after: { f in seen[f] = (n.xScale, n.alpha, n.parent != nil) })
        XCTAssertEqual(seen[1]?.0, 0.60000002384185791)
        XCTAssertEqual(seen[2]?.0, 0.69523811340332031)
        XCTAssertEqual(seen[8]?.0, 1.2666667699813843)
        XCTAssertEqual(seen[8]?.1, 1, "still waiting")
        XCTAssertEqual(seen[9]?.0, 1.3619047403335571)
        XCTAssertEqual(seen[9]?.1, 0.93939387798309326, "the fade already ran 1/75 s in the frame the wait ended")
        XCTAssertEqual(seen[10]?.0, 1.3999999761581421)
        XCTAssertEqual(seen[10]?.1, 0.863636314868927)
        XCTAssertEqual(seen[21]?.1, 0.030303001403808594)
        XCTAssertEqual(seen[21]?.2, true)
        XCTAssertEqual(seen[22]?.2, false)
        XCTAssertEqual(n.yScale, n.xScale)
    }

    /// The shutter: alpha reaches 0 a frame before the step counts as done (SpriteKit compares the elapsed time with the
    /// 32-bit duration), so the node goes in the next frame.
    func testDoneUsesTheThirtyTwoBitDuration() async {
        let root = PlazaNode()
        let n = node(in: root)
        n.alpha = 0.7
        let tweens = PlazaTweens()
        var seen: [Int: (CGFloat, Bool)] = [:]
        drive(tweens, through: 15, before: { f in if f == 1 { tweens.run(.sequence([.fadeOut(duration: 0.2), .removeFromParent]), on: n) } },
              after: { f in seen[f] = (n.alpha, n.parent != nil) })
        XCTAssertEqual(seen[1]?.0, 0.69999998807907104)
        XCTAssertEqual(seen[2]?.0, 0.64166665077209473)
        XCTAssertEqual(seen[12]?.0, 0.058333318680524826)
        XCTAssertEqual(seen[13]?.0, 0)
        XCTAssertEqual(seen[13]?.1, true)
        XCTAssertEqual(seen[14]?.1, false)
    }

    func testGroupEndsWithItsLongestChild() async {
        let tweens = PlazaTweens()
        var calledAt: Int?
        var frame = 0
        drive(tweens, through: 30, before: { f in
            frame = f
            if f == 2 { tweens.run(.sequence([.group([.wait(0.1), .wait(0.3)]), .call { calledAt = frame }]), on: nil) }
        }, after: { _ in })
        XCTAssertEqual(calledAt, 2 + 19, "0.3 s is 18 frames, but Float(0.3) is a hair above 18/60")
        XCTAssertEqual(tweens.count, 0)
    }

    /// The delayed landing puff: a scene-level `call` starts new tweens, which take their first step in that same frame.
    func testACallStartsTweensThatStepInTheSameFrame() async {
        let root = PlazaNode()
        let tweens = PlazaTweens()
        var made: PlazaSprite?
        var xs: [Int: CGFloat] = [:]
        drive(tweens, through: 12, before: { f in
            if f == 2 {
                tweens.run(.sequence([.wait(0.1), .call {
                    let n = self.node(in: root, x: 0, y: 0)
                    tweens.run(.moveBy(dx: 1, dy: 0, duration: 0.2), on: n)
                    made = n
                }]), on: nil)
            }
        }, after: { f in if let made { xs[f] = made.position.x } })
        XCTAssertNil(xs[8])
        XCTAssertEqual(xs[9], 0)
        XCTAssertEqual(xs[10], 0.0833333358168602)
        XCTAssertEqual(xs[11], 0.1666666716337204)
    }

    func testATweenOnARemovedNodeStops() async {
        let root = PlazaNode()
        let n = node(in: root)
        let tweens = PlazaTweens()
        tweens.run(.fadeOut(duration: 1), on: n)
        tweens.advance(by: 0)
        tweens.advance(by: 0.1)
        let alpha = n.alpha
        XCTAssertLessThan(alpha, 1)
        n.removeFromParent()
        tweens.advance(by: 0.1)
        XCTAssertEqual(n.alpha, alpha, "SpriteKit does not run the actions of a node that left the tree")
        XCTAssertEqual(tweens.count, 0)
    }

    func testNothingMovesWithoutAFrame() async {
        let root = PlazaNode()
        let n = node(in: root)
        let tweens = PlazaTweens()
        tweens.run(.moveBy(dx: 10, dy: 0, duration: 0.2), on: n)
        XCTAssertEqual(n.position.x, 100.5)
        XCTAssertEqual(tweens.count, 1, "a tween only advances when the scene steps it: a paused or hidden plaza gets no frames")
    }
}
