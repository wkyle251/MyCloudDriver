import Foundation

@main
enum SharedLinkInputTests {
    static func main() {
        let paste = CGSize(width: 80, height: 26)
        let add = CGSize(width: 110, height: 26)
        func frames(_ width: CGFloat) -> [CGRect] {
            SharedLinkInputGeometry.frames(width: width, paste: paste, add: add)
        }

        let wide = frames(1000)
        precondition(wide.allSatisfy { $0.minY == 0 })
        precondition(wide[0].width >= 260 && wide[1].width >= 175)
        let compact = frames(500)
        precondition(compact[0].width == 500 && compact[0].minY == 0)
        precondition(compact[1].minY > 0 && compact[1].minY == compact[2].minY && compact[2].minY == compact[3].minY)
        let narrow = frames(300)
        precondition(narrow[0].width == 300 && narrow[1].width == 300)
        precondition(narrow[2].minY > narrow[1].minY && narrow[2].minY == narrow[3].minY)
        let tiny = frames(100)
        precondition(zip(tiny, tiny.dropFirst()).allSatisfy { $0.maxY < $1.minY })
        print("PASS: one-, two-, three- and four-row input layouts")

        for buttonHeight: CGFloat in [20, 30, 44] {
            for index in 0...6400 {
                let width = CGFloat(index) / 4
                let frames = SharedLinkInputGeometry.frames(
                    width: width, paste: CGSize(width: 80, height: buttonHeight), add: add)
                precondition(frames.count == 4)
                for (index, frame) in frames.enumerated() {
                    precondition(frame.minX >= 0 && frame.width >= 0 && frame.height >= 30)
                    precondition(frame.maxX <= width + 0.0001 && frame.maxY.isFinite)
                    for next in frames.dropFirst(index + 1) {
                        precondition(frame.intersection(next).isEmpty)
                    }
                }
            }
        }
        print("PASS: fields/buttons never overlap or extend outside 0–1600 pt viewports, including fractional widths")

        for width: CGFloat in [-1, .infinity, .nan] {
            let result = frames(width)
            precondition(result.count == 4 && result.allSatisfy { $0.width.isFinite && $0.width >= 0 })
        }
        print("PASS: transient zero/invalid layout proposals remain bounded; no app minimum width")
    }
}
