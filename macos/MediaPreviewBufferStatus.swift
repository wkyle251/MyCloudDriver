import SwiftUI

/// Display values only: the player and its cache keep ownership of buffering.
struct MediaPreviewBufferSummary {
    var title: String
    var symbol: String
    var color: Color
    var source: String
    var sourceDetails: String? = nil
    var amount: String? = nil
    var amountSuffix: String? = nil
    var fraction: Double? = nil
    var speed: String? = nil
    var ranges: [Range<Double>]? = nil
    var showsProgress = true
    var footnote: String? = nil
    var help: String? = nil
}

/// One hierarchy for status, one byte summary, and one accurate range track.
struct MediaPreviewBufferStatusView<Details: View>: View {
    let summary: MediaPreviewBufferSummary
    let details: Details

    init(_ summary: MediaPreviewBufferSummary, @ViewBuilder details: () -> Details) {
        self.summary = summary
        self.details = details()
    }

    private var fraction: Double? {
        summary.fraction.flatMap { $0.isFinite ? min(max($0, 0), 1) : nil }
    }

    private var percentage: String? {
        fraction.map { $0.formatted(.percent.precision(.fractionLength(0...1))) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline, spacing: 10) {
                Label(summary.title, systemImage: summary.symbol)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(summary.color)
                    .lineLimit(1)
                    .help(summary.title)
                Spacer(minLength: 4)
                if let speed = summary.speed {
                    Label(speed, systemImage: "arrow.down")
                        .font(.caption).monospacedDigit()
                        .foregroundStyle(.secondary)
                        .fixedSize()
                        .accessibilityLabel("Transfer speed: \(speed)")
                }
            }

            if summary.amount != nil || percentage != nil {
                ViewThatFits(in: .horizontal) {
                    HStack(alignment: .firstTextBaseline, spacing: 12) {
                        HStack(alignment: .firstTextBaseline, spacing: 4) {
                            amount
                            suffix
                        }.fixedSize()
                        Spacer(minLength: 0)
                        percent.fixedSize()
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(alignment: .firstTextBaseline) {
                            amount
                            Spacer(minLength: 4)
                            percent
                        }
                        suffix
                    }
                }
            }

            if summary.showsProgress {
                if let ranges = summary.ranges, !ranges.isEmpty || fraction != nil {
                    retainedRanges(ranges)
                } else {
                    ProgressView(value: fraction)
                        .progressViewStyle(.linear).tint(.cyan)
                }
            }

            details

            if let footnote = summary.footnote {
                Text(footnote).font(.caption2).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Text(summary.source)
                    .font(.caption2).foregroundStyle(.secondary)
                    .lineLimit(1).truncationMode(.middle)
                    .help(summary.sourceDetails ?? summary.source)
                Spacer(minLength: 0)
                if let help = summary.help {
                    Image(systemName: "info.circle")
                        .font(.caption).foregroundStyle(.secondary)
                        .help(help)
                        .accessibilityLabel("About buffering")
                        .accessibilityHint(help)
                }
            }
        }
        .padding(.top, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder private var amount: some View {
        if let amount = summary.amount {
            Text(amount).font(.callout.weight(.semibold)).monospacedDigit()
        }
    }

    @ViewBuilder private var suffix: some View {
        if let suffix = summary.amountSuffix {
            Text(suffix).font(.caption).foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var percent: some View {
        if let percentage {
            Text(percentage).font(.caption.weight(.semibold))
                .foregroundStyle(.secondary).monospacedDigit()
        }
    }

    private func retainedRanges(_ ranges: [Range<Double>]) -> some View {
        GeometryReader { geometry in
            let width = max(geometry.size.width, 0)
            ZStack(alignment: .leading) {
                Capsule().fill(Color.primary.opacity(0.09))
                ForEach(Array(ranges.enumerated()), id: \.offset) { _, range in
                    let start = min(max(range.lowerBound, 0), 1)
                    let end = min(max(range.upperBound, start), 1)
                    Capsule().fill(Color.cyan)
                        .frame(width: min(max((end - start) * width, 2), width * (1 - start)))
                        .offset(x: start * width)
                }
            }.frame(height: 6)
        }
        .frame(height: 6)
        .accessibilityLabel("Buffered parts of the file")
        .accessibilityValue([percentage, summary.amount, summary.amountSuffix].compactMap { $0 }.joined(separator: ", "))
    }
}
