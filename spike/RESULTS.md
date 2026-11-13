# Windows port — stage 0 results

## Experiment 4: a Mac plaza layer behind a drawing interface — YES

- `PlazaPondLayer` no longer imports SpriteKit. It talks to `DrawFactory`/`DrawNode`/`DrawSprite`/`DrawTexture`
  (`SpikeDraw.swift`, 20 lines); the SpriteKit side is `SpikeDrawSpriteKit.swift` (about 40 lines).
- Offscreen `SKRenderer` render, 640x480, scripted splashes and bubbles, 3 timestamps x 3 conditions
  (plain water, a multiply tint above, a multiplyX2 tint above): 9/9 byte-identical before and after.
  Node-tree dumps (position, z, alpha, hidden, size, texture size, blend) identical 9/9.
- Cost: 6000 scripted frames of the layer, 5 runs. Median before 28.3 ms, after 28.6 ms (other runs of the
  unchanged code ranged 23–29 ms, so the difference is inside the noise).
- Existing tests: `swift test --filter Pond` 85 tests, 0 failures. No test file changed. Four test sites read
  `layer.children`; a 3-line SpriteKit-side extension kept them compiling. In stage 2 such tests should read a
  recording implementation instead.
- Rulings: the render used the layer in a bare `SKScene` rather than the full `PlazaScene` at noon / night /
  snow, because those conditions are other layers above or below the pond nodes and do not change the pond's own
  nodes; blend interaction is covered by the two tint conditions. Textures still come from `CGImage`
  (`PlazaPondArt`); making images without CoreGraphics is experiment 3's subject.
- Not learned here: the cost of a layer with many more nodes per frame (`PlazaScene`, `PlazaActor`).
