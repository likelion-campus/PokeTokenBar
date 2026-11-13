import CD2D
import Foundation

// Throwaway (spec §9 experiment 3). ptbdraw <resources dir> <out.png> [--hardware]
let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: ptbdraw <resources dir> <out.png> [--hardware]"); exit(2) }
let dir = args[1], out = args[2], hardware: Int32 = args.contains("--hardware") ? 1 : 0

func die(_ what: String) -> Never { print("FAIL \(what): \(String(cString: ptb_last_error()))"); exit(1) }

guard let canvas = ptb_canvas_create(960, 640, hardware) else { die("canvas") }
print("canvas ok (\(hardware == 1 ? "GPU" : "WARP software"))")
for font in ["Galmuri11.ttf", "Pretendard-Bold.otf"] where ptb_add_font(canvas, "\(dir)/\(font)") == 0 { die("font \(font)") }
let tiles = ptb_load_png(canvas, "\(dir)/plaza-tiles.png"), grass = ptb_load_png(canvas, "\(dir)/plaza-tallgrass.png")
guard tiles >= 0, grass >= 0 else { die("png") }

ptb_begin(canvas, 0.12, 0.49, 0.72)
// 20 x 12 tiles from the sheet at 3x, nearest neighbour.
for ty in 0..<12 {
    for tx in 0..<20 {
        ptb_draw_bitmap(canvas, tiles, Float(tx * 16), Float(ty * 16), 16, 16, Float(tx * 48), Float(ty * 48), 48, 48, 1, 0)
    }
}
// A "sprite": normal, then flipped at half alpha.
ptb_draw_bitmap(canvas, tiles, 144, 208, 96, 48, 40, 500, 192, 96, 1, 0)
ptb_draw_bitmap(canvas, tiles, 144, 208, 96, 48, 250, 500, 192, 96, 0.5, 1)
// Pixel font at its native size, aliased.
ptb_fill_round_rect(canvas, 40, 300, 300, 40, 0, 0, 0, 0, 0.6)
ptb_draw_text(canvas, "광장 Plaza 123", "Galmuri11", 12, 0, 48, 304, 1, 1, 1, 1, 0)
ptb_draw_text(canvas, "광장 Plaza 123", "Galmuri11", 24, 0, 48, 318, 1, 1, 1, 1, 0)
// Name plate in Pretendard Bold.
ptb_fill_round_rect(canvas, 40, 380, 120, 36, 8, 0.1, 0.1, 0.12, 0.85)
ptb_draw_text(canvas, "시무 Simu", "Pretendard", 18, 1, 52, 386, 1, 1, 1, 0, 0)
// Colour emoji.
ptb_draw_text(canvas, "🎉 👋", "Segoe UI Emoji", 32, 0, 200, 376, 1, 1, 1, 0, 1)
// Daylight tint: multiply the right half.
guard ptb_end_with_multiply(canvas, 480, 0, 480, 640, 0.45, 0.5, 0.8) == 1 else { die("multiply") }
guard ptb_save_png(canvas, out) == 1 else { die("save") }
let note = String(cString: ptb_last_error())
print("saved \(out)" + (note.isEmpty ? "" : " — note: \(note)"))
ptb_canvas_free(canvas)
