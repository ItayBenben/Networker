import Charts
import SwiftUI

/// Bytes received (bottom) and sent (top) per time slice, drawn as explicitly stacked rectangles.
struct TrafficBarChart: View {
    let buckets: [TrafficBucket]
    let bucketSeconds: TimeInterval
    let start: Date
    let end: Date

    var body: some View {
        Chart {
            ForEach(buckets, id: \.start) { bucket in
                let barEnd = bucket.start.addingTimeInterval(bucketSeconds * 0.92)
                RectangleMark(
                    xStart: .value("Start", bucket.start),
                    xEnd: .value("End", barEnd),
                    yStart: .value("From", 0.0),
                    yEnd: .value("To", Double(bucket.bytesIn))
                )
                .foregroundStyle(by: .value("Direction", "Received"))
                RectangleMark(
                    xStart: .value("Start", bucket.start),
                    xEnd: .value("End", barEnd),
                    yStart: .value("From", Double(bucket.bytesIn)),
                    yEnd: .value("To", Double(bucket.bytesIn &+ bucket.bytesOut))
                )
                .foregroundStyle(by: .value("Direction", "Sent"))
            }
        }
        .chartXScale(domain: start ... end)
        .chartForegroundStyleScale(["Received": Color.blue, "Sent": Color.orange])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Format.bytes(amount))
                    }
                }
            }
        }
        .chartLegend(position: .top, alignment: .leading)
        .overlay {
            if buckets.isEmpty {
                Text("No traffic in this period")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Bytes per second over the last two minutes.
struct LiveThroughputChart: View {
    let buckets: [TrafficBucket]

    var body: some View {
        Chart {
            ForEach(buckets, id: \.start) { bucket in
                AreaMark(
                    x: .value("Time", bucket.start),
                    y: .value("Bytes/s", Double(bucket.bytesIn)),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value("Direction", "Received"))
                .opacity(0.25)
                LineMark(
                    x: .value("Time", bucket.start),
                    y: .value("Bytes/s", Double(bucket.bytesIn)),
                    series: .value("Direction", "Received")
                )
                .foregroundStyle(by: .value("Direction", "Received"))
                AreaMark(
                    x: .value("Time", bucket.start),
                    y: .value("Bytes/s", Double(bucket.bytesOut)),
                    stacking: .unstacked
                )
                .foregroundStyle(by: .value("Direction", "Sent"))
                .opacity(0.25)
                LineMark(
                    x: .value("Time", bucket.start),
                    y: .value("Bytes/s", Double(bucket.bytesOut)),
                    series: .value("Direction", "Sent")
                )
                .foregroundStyle(by: .value("Direction", "Sent"))
            }
        }
        .chartForegroundStyleScale(["Received": Color.blue, "Sent": Color.orange])
        .chartYAxis {
            AxisMarks(position: .leading) { value in
                AxisGridLine()
                AxisValueLabel {
                    if let amount = value.as(Double.self) {
                        Text(Format.rate(amount))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: .stride(by: .second, count: 30)) { _ in
                AxisGridLine()
                AxisValueLabel(format: .dateTime.hour().minute().second())
            }
        }
        .chartLegend(position: .top, alignment: .leading)
    }
}

/// Number of new connections / sessions per time slice.
struct ConnectionsChart: View {
    let buckets: [TrafficBucket]
    let bucketSeconds: TimeInterval
    let start: Date
    let end: Date

    var body: some View {
        Chart {
            ForEach(buckets, id: \.start) { bucket in
                RectangleMark(
                    xStart: .value("Start", bucket.start),
                    xEnd: .value("End", bucket.start.addingTimeInterval(bucketSeconds * 0.92)),
                    yStart: .value("From", 0.0),
                    yEnd: .value("To", Double(bucket.connections))
                )
                .foregroundStyle(Color.purple)
            }
        }
        .chartXScale(domain: start ... end)
        .chartYAxis {
            AxisMarks(position: .leading)
        }
        .overlay {
            if buckets.allSatisfy({ $0.connections == 0 }) {
                Text("No new connections in this period")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

/// Horizontal bars: bytes per physical network interface.
struct InterfaceChart: View {
    let totals: [(name: String, bytes: UInt64)]

    var body: some View {
        Chart {
            ForEach(totals, id: \.name) { item in
                BarMark(
                    x: .value("Bytes", Double(item.bytes)),
                    y: .value("Interface", item.name)
                )
                .foregroundStyle(Color.teal)
                .annotation(position: .trailing) {
                    Text(Format.bytes(item.bytes)).font(.caption2)
                }
            }
        }
        .chartXAxis(.hidden)
    }
}

/// Segmented control for the history charts.
struct TimeRangePicker: View {
    @Binding var range: TimeRange

    var body: some View {
        Picker("Range", selection: $range) {
            ForEach(TimeRange.allCases) { range in
                Text(range.rawValue).tag(range)
            }
        }
        .pickerStyle(.segmented)
    }
}

extension TimeRange {
    /// The chart window ending now, aligned to the bucket size so the first bar is not clipped.
    func window(endingAt end: Date) -> (start: Date, end: Date) {
        let alignedEnd = Date(timeIntervalSince1970: (end.timeIntervalSince1970 / bucketSeconds).rounded(.up) * bucketSeconds)
        return (alignedEnd.addingTimeInterval(-seconds), alignedEnd)
    }
}
