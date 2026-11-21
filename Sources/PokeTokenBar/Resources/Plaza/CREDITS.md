# Plaza resource credits

## Tileset (plaza-tiles.png)
- "Zelda-like tilesets and sprites" (`gfx/Overworld.png`, unmodified) by ArMM1998
- License: CC0 (public domain)
- Source: https://opengameart.org/sites/default/files/gfx_3.zip

## Fonts (Galmuri11.ttf, Galmuri14.ttf)
- Galmuri 2.40.3 by Lee Minseo
- License: SIL Open Font License 1.1 (see Galmuri-OFL.txt)
- Sources: https://cdn.jsdelivr.net/npm/galmuri@2.40.3/dist/Galmuri11.ttf,
  https://cdn.jsdelivr.net/npm/galmuri@2.40.3/dist/Galmuri14.ttf

## Fonts, Windows build (Pretendard-Regular.otf, Pretendard-SemiBold.otf, Pretendard-Bold.otf)
- Pretendard 1.3.9 by Kil Hyung-jin (static OTF files, unmodified, from `Pretendard-1.3.9.zip`, `public/static/`)
- License: SIL Open Font License 1.1 (see Pretendard-OFL.txt)
- Source: https://github.com/orioncactus/pretendard/releases/tag/v1.3.9
- Committed in `windows/resources/Plaza/` and shipped in the Windows app's `Resources\Plaza\` folder (the Mac app does not bundle them).
  SHA-256: Regular `3ffbacde6ab8411f1d2db54bb9b1f0b3ee2a738932033722cf0388c06aed1c93`,
  SemiBold `c89bc43027dc7cde5726e96223376f8eec09302b2fc1f8147fd5b57cfc376118`,
  Bold `2e91915fab54df71cc9598ebf608b2bdb54c6fe3c066ac61dff0bc44fca71cc7`.

## Tall grass (plaza-tallgrass.png)
- "Pokemon inspired 16x16 tiles" (`tilemap.png`, unmodified) by RedVoxel
- License: CC-BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/). This file is not under the app's MIT license. — full text: CC-BY-SA-3.0.txt
- Copyright notice: https://red-voxel.itch.io/ - RedVoxel
- Source: https://opengameart.org/content/pokemon-inspired-16x16-tiles
- In the plaza's winter and autumn the app recolours this image at runtime (exact colour swaps, no new shapes); the recoloured image is a derivative and stays under CC-BY-SA 3.0.

## Water balloon (plaza-water-balloon.png)
- "Water gun fight art" (`waterballoon.png`, unmodified) by rrcaseyr
- License: CC-BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/). This file is not under the app's MIT license. — full text: CC-BY-SA-3.0.txt
- Source: https://opengameart.org/content/water-gun-fight-art
- Thrown in the plaza's summer. The app draws it as it is.

## Leaf clumps (plaza-leaf-sheet.png)
- "[LPC] Leaf Recolor" (`lpc leaf recolors.png`, unmodified) by William Thompson, leaves recoloured from Johann Charlot's "Shoot'em up graphic kit", a Liberated Pixel Cup work
- License: CC-BY-SA 3.0 (https://creativecommons.org/licenses/by-sa/3.0/), chosen from the work's CC-BY-SA 3.0 / GPL 3.0 dual licence. This file is not under the app's MIT license. — full text: CC-BY-SA-3.0.txt
- Source: https://opengameart.org/content/lpc-leaf-recolor
- SHA-256: 4ad08bd59fbd202e7193befe3c40cd19a144a87ce30b06e5171a89753a874c17
- Spring throws the pink clump at (33, 129) and autumn the red and orange clump at (33, 33), each 17×15, cut from the sheet at runtime and drawn as they are. The cut cells are a derivative and stay under CC-BY-SA 3.0.

## Ice cracks (plaza-ice-cracks.png)
- "Ice Mountains Tileset" (`ice_mountain_tileset.png`, unmodified) by CookieEfedu
- License: CC-BY 4.0 (https://creativecommons.org/licenses/by/4.0/). This file is not under the app's MIT license.
- Source: https://opengameart.org/content/ice-mountains-tileset
- The app keeps only the crack pixels of six cells and recolours them at runtime (exact colour swaps, no new shapes); the result is a derivative and stays under CC-BY 4.0.

## Ice gloss (plaza-ice-gloss.png)
- "Some 16x16 floor tiles" (`stuff_1.png`, unmodified) by ChikenwingJJA
- License: CC0 (public domain)
- Source: https://opengameart.org/content/some-16x16-floor-tiles
- The app recolours one cell at runtime.

## Ice shards (plaza-ice-shatter.gif)
- "Shattering Boulder" (`boulder.gif`, unmodified) by Spring Spring
- License: CC0 (public domain)
- Source: https://opengameart.org/content/shattering-boulder
- The app recolours frames 2–4 at runtime.

## Steam (plaza-steam.png)
- "Smoke Puff" (`smoke_5.png`, unmodified; the page lists it as `smoke.png`) by Aidan_Walker
- License: CC0 (public domain)
- Source: https://opengameart.org/content/smoke-puff
- SHA-256: 246e0f333142c5d388dab36d50caf19fe508e8274ad4ecf7c7b96c0b92b0b8f8
- The plaza hot spring's steam: the first six of its seven 32×32 cells (the seventh is empty), cut at runtime and drawn as they are with a changing transparency.
