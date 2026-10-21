import SwiftUI

struct StarRatingView: View {
    let rating: Int
    let isInteractive: Bool
    let onRatingChange: (Int) -> Void

    init(rating: Int, isInteractive: Bool = true, onRatingChange: @escaping (Int) -> Void = { _ in }) {
        self.rating = rating
        self.isInteractive = isInteractive
        self.onRatingChange = onRatingChange
    }

    var body: some View {
        // Each star owns its slot rather than just its glyph: with HStack
        // spacing the 6 pt gaps between stars were dead, so a click that landed
        // between two stars did nothing and the glyph itself was only a ~16 pt
        // target. spacing 0 + a 22x20 slot keeps the same visual rhythm while
        // making every pixel of the control live.
        HStack(spacing: 0) {
            ForEach(1...5, id: \.self) { index in
                Image(systemName: index <= rating ? "star.fill" : "star")
                    .font(.body)
                    .foregroundColor(index <= rating ? .yellow : .gray)
                    .frame(width: 22, height: 20)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard isInteractive else { return }
                        onRatingChange(index)
                    }
                    .help(isInteractive ? "Rate \(index) star(s)" : "")
            }
        }
        .accessibilityLabel("Rating")
        .accessibilityValue("\(rating) out of 5 stars")
    }
}
