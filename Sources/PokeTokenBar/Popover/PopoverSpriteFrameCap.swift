import Foundation

/// The Mac's frame-rate cap for the always-on surfaces (`GIFDecoder.capFrameRate`, `UI/SpriteAnimation.swift`) on the
/// shared picture type, for the floating pet on Windows (stage 7 Task 22). `twins.txt` holds the body to the Mac's and
/// `PopoverPetTwinEquivalenceTests+Mac` drives both over the same delay lists.
///
/// The cap keeps the playback speed: frames are decimated, not held longer. A run of frames is shown as its first frame for
/// the run's whole length once the run reaches `floor`, so one loop lasts as long as the GIF's and only the frames per
/// second fall to `1 / floor`. A last run shorter than `floor` is added to the frame before it.
enum PopoverSpriteFrameCap {
    static func capFrameRate(_ frames: [(image: PlazaImage, delay: TimeInterval)],
                             floor: TimeInterval) -> [(image: PlazaImage, delay: TimeInterval)] {
        guard floor > 0, frames.count > 1 else { return frames }
        var out: [(image: PlazaImage, delay: TimeInterval)] = []
        var held: PlazaImage?          // 현재 구간을 대표하는(= 구간 첫) 프레임
        var acc: TimeInterval = 0   // 구간 누적 길이
        for f in frames {
            if held == nil { held = f.image }
            acc += f.delay
            // 부동소수 누적(0.05×4 = 0.20000000000000004 / 0.19999999999999998)에 걸려 구간이
            // 한 프레임씩 밀리지 않게 epsilon 을 둔다.
            if acc + 1e-9 >= floor {
                out.append((held!, acc))
                held = nil
                acc = 0
            }
        }
        // 마지막 구간이 floor 에 못 미치면 직전 프레임에 합친다 — 총 길이(재생 속도)를 보존한다.
        if let tail = held, acc > 0 {
            if out.isEmpty { out.append((tail, acc)) } else { out[out.count - 1].delay += acc }
        }
        return out
    }
}
