import AppKit
import Charts
import SwiftUI

struct PowerBarView: View {
    @Bindable var monitor: PowerMonitor
    @Bindable var launchAtLogin: LaunchAtLoginController
    @State private var section: Section = .overview

    enum Section: String, CaseIterable, Identifiable {
        case overview = "Overview"
        case activity = "Activity"
        case history = "History"
        case snapshots = "Snapshots"
        case connections = "Ports"
        var id: Self { self }
    }

    var body: some View {
        VStack(spacing: 0) {
            header

            Picker("Section", selection: $section) {
                ForEach(Section.allCases) { section in
                    Text(section.rawValue).tag(section)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .padding(.horizontal, 16)
            .padding(.bottom, 12)

            Divider()

            Group {
                switch section {
                case .overview: OverviewView(monitor: monitor)
                case .activity: ActivityView(monitor: monitor)
                case .history: HistoryView(monitor: monitor)
                case .snapshots: SnapshotsView(monitor: monitor)
                case .connections: ConnectionsView(monitor: monitor)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Divider()
            footer
        }
        .frame(width: 370, height: 520)
        .background(.regularMaterial)
    }

    private var header: some View {
        HStack(alignment: .center, spacing: 14) {
            Image(systemName: monitor.reading.symbolName)
                .font(.system(size: 31, weight: .medium))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(levelColor)
                .contentTransition(.symbolEffect(.replace))

            VStack(alignment: .leading, spacing: 2) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(monitor.reading.levelText)
                        .font(.system(size: 29, weight: .semibold, design: .rounded))
                        .contentTransition(.numericText())
                    Text(monitor.reading.statusTitle)
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                Text(monitor.reading.statusDetail)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer()
            Button {
                Task { await monitor.refreshAll() }
            } label: {
                if monitor.isRefreshing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .buttonStyle(.borderless)
            .help("Refresh now")
            .accessibilityLabel("Refresh power status")
        }
        .padding(16)
    }

    private var footer: some View {
        HStack {
            if let error = monitor.lastError {
                Label(error, systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help(error)
            } else if let lastUpdated = monitor.lastUpdated {
                Text("Updated \(lastUpdated.relativeDescription)")
                    .foregroundStyle(.tertiary)
            } else {
                Text("Reading power status…")
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            Menu {
                Toggle("Cable Notifications", isOn: Binding(
                    get: { monitor.cableNotificationsEnabled },
                    set: { monitor.setCableNotificationsEnabled($0) }
                ))
                Text("Permission: \(monitor.cableNotificationAuthorization.label)")
                Button("Send Test Notification") {
                    monitor.sendTestCableNotification()
                }
                if monitor.cableNotificationAuthorization == .denied {
                    Button("Open Notification Settings…") {
                        monitor.openNotificationSettings()
                    }
                }
                if let feedback = monitor.cableNotificationFeedback {
                    Text(feedback)
                }
                Divider()
                Toggle("Launch at Login", isOn: Binding(
                    get: { launchAtLogin.isEnabled },
                    set: { launchAtLogin.setEnabled($0) }
                ))
                if launchAtLogin.requiresApproval {
                    Button("Approve in System Settings…") {
                        launchAtLogin.openSettings()
                    }
                }
                if let error = launchAtLogin.errorMessage {
                    Text(error)
                }
                Divider()
                Button("Quit PowerBar") { NSApplication.shared.terminate(nil) }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
            .help("PowerBar settings")
            .accessibilityLabel("PowerBar settings")
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .frame(height: 38)
    }

    private var levelColor: Color {
        if monitor.reading.isOnExternalPower { return .green }
        if (monitor.reading.percentage ?? 100) <= 20 { return .red }
        return .primary
    }
}

private struct HistoryView: View {
    let monitor: PowerMonitor
    @State private var range: HistoryRange = .sixHours

    private var samples: [BatteryHistorySample] {
        BatteryHistoryPolicy.filtered(monitor.history, range: range, now: Date())
    }

    private var percentageSamples: [BatteryHistorySample] {
        samples.filter { $0.percentage != nil }
    }

    private var wattSamples: [BatteryHistorySample] {
        samples.filter { $0.estimatedWatts != nil }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("BATTERY HISTORY")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Sampled automatically each minute")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Picker("Range", selection: $range) {
                    ForEach(HistoryRange.allCases) { range in
                        Text(range.rawValue).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 138)
            }
            .padding(16)

            Divider()

            if monitor.historyLoadError != nil {
                ContentUnavailableView {
                    Label("Couldn’t Read History", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("PowerBar left history.json unchanged so it can be recovered.")
                } actions: {
                    Button("Show in Finder") { monitor.openHistoryFile() }
                }
            } else if samples.count < 2 {
                ContentUnavailableView(
                    "Gathering History",
                    systemImage: "chart.xyaxis.line",
                    description: Text("Keep PowerBar running for a few minutes to see battery level and power flow over time.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        historySummary
                        batteryChart
                        wattChart
                    }
                    .padding(16)
                }
            }
        }
    }

    private var historySummary: some View {
        HStack(spacing: 0) {
            summaryValue("LEVEL CHANGE", value: levelChangeText)
            Divider().frame(height: 34).padding(.horizontal, 12)
            summaryValue("AVERAGE FLOW", value: averageWattsText)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private var batteryChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartHeader("BATTERY LEVEL", value: percentageSamples.last?.percentage.map { "\($0)%" } ?? "—")
            Chart(percentageSamples) { sample in
                if let percentage = sample.percentage {
                    AreaMark(
                        x: .value("Time", sample.capturedAt),
                        yStart: .value("Floor", chartFloor),
                        yEnd: .value("Battery", percentage)
                    )
                    .foregroundStyle(.linearGradient(colors: [.green.opacity(0.22), .green.opacity(0.02)], startPoint: .top, endPoint: .bottom))
                    LineMark(x: .value("Time", sample.capturedAt), y: .value("Battery", percentage))
                        .foregroundStyle(.green)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                        .interpolationMethod(.catmullRom)
                }
            }
            .chartYScale(domain: chartFloor...100)
            .chartYAxis {
                AxisMarks(position: .leading, values: [chartFloor, 100]) { value in
                    AxisValueLabel {
                        if let number = value.as(Int.self) { Text("\(number)%") }
                    }
                    AxisGridLine().foregroundStyle(.quaternary)
                }
            }
            .chartXAxis { compactTimeAxis }
            .frame(height: 105)
        }
        .cardStyle()
        .accessibilityElement(children: .contain)
    }

    private var wattChart: some View {
        VStack(alignment: .leading, spacing: 8) {
            chartHeader("POWER FLOW", value: wattSamples.last?.estimatedWatts.map { String(format: "%+.1f W", $0) } ?? "—")
            Chart(wattSamples) { sample in
                if let watts = sample.estimatedWatts {
                    RuleMark(y: .value("Zero", 0))
                        .foregroundStyle(.quaternary)
                    LineMark(x: .value("Time", sample.capturedAt), y: .value("Watts", watts))
                        .foregroundStyle(sample.isCharging ? .green : .orange)
                        .lineStyle(.init(lineWidth: 2, lineCap: .round, lineJoin: .round))
                }
            }
            .chartYAxis {
                AxisMarks(position: .leading, values: .automatic(desiredCount: 3)) {
                    AxisValueLabel(format: Decimal.FormatStyle().precision(.fractionLength(0)))
                    AxisGridLine().foregroundStyle(.quaternary)
                }
            }
            .chartXAxis { compactTimeAxis }
            .frame(height: 105)
            HStack(spacing: 12) {
                Label("Charging", systemImage: "arrow.up").foregroundStyle(.green)
                Label("Battery draw", systemImage: "arrow.down").foregroundStyle(.orange)
            }
            .font(.caption2)
        }
        .cardStyle()
        .accessibilityElement(children: .contain)
    }

    private var compactTimeAxis: some AxisContent {
        AxisMarks(values: .automatic(desiredCount: 3)) { value in
            AxisValueLabel(format: .dateTime.hour().minute())
            AxisGridLine().foregroundStyle(.quaternary)
        }
    }

    private func chartHeader(_ title: String, value: String) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Spacer()
            Text(value).font(.subheadline.weight(.medium)).monospacedDigit()
        }
    }

    private func summaryValue(_ title: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            Text(value).font(.headline).monospacedDigit()
        }
    }

    private var levelChangeText: String {
        guard let first = percentageSamples.first?.percentage,
              let last = percentageSamples.last?.percentage else { return "—" }
        return (last - first).signed(" pp")
    }

    private var averageWattsText: String {
        let values = wattSamples.compactMap(\.estimatedWatts)
        guard !values.isEmpty else { return "—" }
        return String(format: "%+.1f W", values.reduce(0, +) / Double(values.count))
    }

    private var chartFloor: Int {
        let minimum = percentageSamples.compactMap(\.percentage).min() ?? 0
        return max(0, (minimum / 10) * 10 - 10)
    }
}

private struct OverviewView: View {
    let monitor: PowerMonitor

    var body: some View {
        ScrollView {
            VStack(spacing: 12) {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("LIVE POWER")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                        Spacer()
                        Image(systemName: "bolt.fill")
                            .foregroundStyle(.tertiary)
                    }
                    Text(monitor.reading.wattsText)
                        .font(.system(size: 30, weight: .semibold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text(monitor.reading.wattDirection)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(monitor.reading.livePowerExplanation)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .cardStyle()

                PowerInputCard(monitor: monitor)

                EnergyUseCard(monitor: monitor)

                VStack(alignment: .leading, spacing: 10) {
                    Text("DETAILS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    ReadingRow(label: "Voltage", value: monitor.reading.voltageMillivolts.map { String(format: "%.2f V", Double($0) / 1000) } ?? "—")
                    ReadingRow(label: "Current", value: monitor.reading.amperageMilliamps.map { String(format: "%.2f A", Double($0) / 1000) } ?? "—")
                    ReadingRow(
                        label: "Battery temperature",
                        value: monitor.reading.temperaturePresentationText,
                        valueColor: temperatureColor
                    )
                    .help("Presentation cue only, not a battery safety limit")
                    ReadingRow(label: "Cycle count", value: monitor.reading.cycleCount.map(String.init) ?? "—")
                    ReadingRow(label: "Maximum capacity", value: monitor.reading.maxCapacity.map { "\($0)%" } ?? "—")
                }
                .cardStyle()
            }
            .padding(16)
        }
    }

    private var temperatureColor: Color {
        switch monitor.reading.temperatureStatus {
        case .normal: .green
        case .warning: Color(red: 0.88, green: 0.56, blue: 0.0)
        case .alert: .red
        case .unavailable: .secondary
        }
    }
}

private struct PowerInputCard: View {
    let monitor: PowerMonitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("POWER INPUT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Image(systemName: "powerplug.fill")
                    .foregroundStyle(.tertiary)
            }

            if !monitor.reading.isOnExternalPower {
                Label("No external power", systemImage: "battery.75percent")
                    .font(.subheadline.weight(.semibold))
                Text("Connect power to inspect the active charging contract.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let port = monitor.cables.primaryPowerPort {
                let diagnostic = port.diagnostic(for: monitor.reading)
                Label(diagnostic.title, systemImage: diagnosticSymbol(diagnostic.severity))
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(diagnosticColor(diagnostic.severity))
                Text(powerInputSummary(for: port))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if diagnostic.severity != .normal {
                    Text(diagnostic.detail)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            } else if let watts = monitor.cables.adapterWatts {
                Label("Power adapter connected", systemImage: "powerplug.fill")
                    .font(.subheadline.weight(.semibold))
                Text("macOS reports the adapter at the system level, without a trustworthy per-port charging contract.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Divider()
                ReadingRow(label: "Adapter", value: "Up to \(watts) W")
            } else {
                Label("External power connected", systemImage: "powerplug.fill")
                    .font(.subheadline.weight(.semibold))
                Text("Waiting for macOS to expose the per-port charging contract.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
    }

    private func powerInputSummary(for port: CablePort) -> String {
        guard let chargerWatts = port.chargerWatts else { return port.displayName }
        return "\(port.displayName) · \(chargerWatts) W adapter"
    }
}

private struct ConnectionsView: View {
    let monitor: PowerMonitor

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PORTS")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Active USB-C and MagSafe ports")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Text("\(monitor.cables.connectedPorts.count) active")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(16)

            Divider()

            if !monitor.cables.isAvailable, monitor.lastUpdated == nil {
                ContentUnavailableView(
                    "Reading Ports",
                    systemImage: "cable.connector",
                    description: Text("Waiting for macOS to report USB-C and MagSafe state.")
                )
            } else if !monitor.cables.isAvailable {
                ContentUnavailableView(
                    "Port Details Unavailable",
                    systemImage: "cable.connector.slash",
                    description: Text("This Mac or the current macOS state is not exposing supported port telemetry.")
                )
            } else if monitor.cables.connectedPorts.isEmpty {
                ContentUnavailableView(
                    "No Active Connections",
                    systemImage: "cable.connector.slash",
                    description: Text("Connect a charger, display, dock, or USB-C device to inspect its exposed capabilities.")
                )
            } else {
                ScrollView {
                    VStack(spacing: 12) {
                        ForEach(monitor.cables.connectedPorts) { port in
                            connectionCard(port)
                        }
                    }
                    .padding(16)
                }
            }
        }
    }

    private func connectionCard(_ port: CablePort) -> some View {
        let diagnostic = port.diagnostic(for: monitor.reading)
        return VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 9) {
                Image(systemName: port.symbolName)
                    .font(.title3)
                    .foregroundStyle(diagnosticColor(diagnostic.severity))
                    .frame(width: 24)
                VStack(alignment: .leading, spacing: 2) {
                    Text(port.displayName)
                        .font(.subheadline.weight(.semibold))
                    Text(diagnostic.title)
                        .font(.caption)
                        .foregroundStyle(diagnosticColor(diagnostic.severity))
                }
                Spacer()
            }

            if diagnostic.severity != .normal {
                Text(diagnostic.detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if port.negotiatedWatts != nil || port.chargerWatts != nil || port.cableWatts != nil || port.cableSpeed != nil || port.transportText != nil {
                Divider()
                if let watts = port.negotiatedWatts {
                    ReadingRow(label: "Negotiated power", value: "\(watts) W")
                }
                if let watts = port.chargerWatts {
                    ReadingRow(label: "Charger capacity", value: "\(watts) W")
                }
                if let watts = port.cableWatts {
                    ReadingRow(label: "Cable capacity", value: "\(watts) W")
                }
                if let speed = port.cableSpeed {
                    ReadingRow(label: "Cable data", value: speed.label)
                }
                if let transport = port.transportText {
                    ReadingRow(label: "Active transport", value: transport)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardStyle()
        .accessibilityElement(children: .combine)
    }
}

private struct EnergyUseCard: View {
    let monitor: PowerMonitor

    private var visibleConsumers: [PowerConsumer] {
        Array(monitor.consumers.prefix(5))
    }

    private var maximumScore: Double {
        max(visibleConsumers.first?.powerScore ?? 1, 1)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("ENERGY USE")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                    Text("Relative impact, not attributed watts")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                if monitor.isRefreshingConsumers {
                    ProgressView().controlSize(.mini)
                } else if let updated = monitor.consumersUpdated {
                    Text(updated.relativeDescription)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }

            if let error = monitor.consumerError {
                VStack(spacing: 4) {
                    Label("Energy measurement unavailable", systemImage: "exclamationmark.triangle")
                    Text(error)
                        .foregroundStyle(.tertiary)
                        .lineLimit(2)
                }
                .font(.caption)
                .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
            } else if visibleConsumers.isEmpty {
                Text(monitor.isRefreshingConsumers ? "Measuring active processes…" : "No significant process activity")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, minHeight: 36, alignment: .center)
            } else {
                ForEach(visibleConsumers) { consumer in
                    consumerRow(consumer)
                }
            }
        }
        .cardStyle()
    }

    private func consumerRow(_ consumer: PowerConsumer) -> some View {
        HStack(spacing: 9) {
            Image(systemName: consumer.symbolName)
                .font(.caption)
                .foregroundStyle(consumer.isApplication ? .blue : .secondary)
                .frame(width: 16)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Text(consumer.displayName)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                    if consumer.processCount > 1 {
                        Text("\(consumer.processCount) processes")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    Spacer()
                    Text(impactLabel(for: consumer))
                        .font(.caption.weight(.medium))
                        .foregroundStyle(impactColor(for: consumer))
                }
                ProgressView(value: consumer.powerScore, total: maximumScore)
                    .progressViewStyle(.linear)
                    .tint(impactColor(for: consumer))
                    .accessibilityLabel("\(consumer.name) relative energy impact")
                    .accessibilityValue(impactLabel(for: consumer))

                if !consumer.isApplication || consumer.displayName != consumer.name {
                    let detail = consumer.displayName == consumer.name
                        ? consumer.explanation
                        : "\(consumer.explanation) · \(consumer.name)"
                    Text(detail)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(consumer.displayName), \(consumer.explanation)")
    }

    private func impactFraction(for consumer: PowerConsumer) -> Double {
        consumer.powerScore / maximumScore
    }

    private func impactLabel(for consumer: PowerConsumer) -> String {
        switch impactFraction(for: consumer) {
        case 0.65...: "High"
        case 0.25...: "Medium"
        default: "Low"
        }
    }

    private func impactColor(for consumer: PowerConsumer) -> Color {
        switch impactFraction(for: consumer) {
        case 0.65...: .orange
        case 0.25...: .yellow
        default: .secondary
        }
    }
}

private struct ActivityView: View {
    let monitor: PowerMonitor

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                activitySection("POWER ASSERTIONS", empty: "No active assertions", items: monitor.assertions) { assertion in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: "moon.zzz")
                            .foregroundStyle(.orange)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(assertion.process).fontWeight(.medium)
                                Spacer()
                                Text(assertion.age).foregroundStyle(.tertiary)
                            }
                            Text(assertion.kind).foregroundStyle(.secondary)
                            Text(assertion.reason).foregroundStyle(.tertiary).lineLimit(2)
                        }
                    }
                }

                activitySection("RECENT POWER EVENTS", empty: "No recent power events", items: monitor.events) { event in
                    HStack(alignment: .top, spacing: 10) {
                        Image(systemName: event.symbolName)
                            .foregroundStyle(event.tintRole.color)
                            .frame(width: 18)
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text(event.title)
                                    .font(.subheadline.weight(.medium))
                                Spacer()
                                if let date = event.date {
                                    Text(date.relativeDescription)
                                        .font(.caption)
                                        .foregroundStyle(.tertiary)
                                }
                            }
                            Text(event.detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                    }
                }
            }
            .font(.caption)
            .padding(16)
        }
    }

    private func activitySection<Item: Identifiable, Content: View>(
        _ title: String,
        empty: String,
        items: [Item],
        @ViewBuilder content: @escaping (Item) -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.caption2.weight(.semibold)).foregroundStyle(.secondary)
            if items.isEmpty {
                Text(empty).foregroundStyle(.tertiary).frame(maxWidth: .infinity, minHeight: 42, alignment: .center)
            } else {
                ForEach(items) { item in
                    content(item)
                    if item.id != items.last?.id { Divider() }
                }
            }
        }
        .cardStyle()
    }
}

private struct SnapshotsView: View {
    let monitor: PowerMonitor

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Button {
                    monitor.captureSnapshot()
                } label: {
                    Label("Capture Snapshot", systemImage: "camera")
                }
                .buttonStyle(.borderedProminent)
                .disabled(monitor.reading.percentage == nil || monitor.snapshotLoadError != nil)
                .help(snapshotCaptureHelp)
                Spacer()
                Button { monitor.openSnapshotsFolder() } label: {
                    Image(systemName: "folder")
                }
                    .buttonStyle(.borderless)
                    .help("Show snapshots in Finder")
                    .accessibilityLabel("Show snapshots in Finder")
                    .disabled(monitor.snapshots.isEmpty && monitor.snapshotLoadError == nil)
            }
            .padding(16)

            if monitor.snapshotLoadError != nil {
                ContentUnavailableView {
                    Label("Couldn’t Read Snapshots", systemImage: "exclamationmark.triangle")
                } description: {
                    Text("PowerBar left snapshots.json unchanged so it can be recovered.")
                } actions: {
                    Button("Show in Finder") { monitor.openSnapshotsFolder() }
                }
            } else if monitor.snapshots.isEmpty {
                ContentUnavailableView("No Snapshots", systemImage: "camera", description: Text("Capture two readings to see how level and draw change."))
            } else {
                List(Array(monitor.snapshots.enumerated()), id: \.element.id) { index, snapshot in
                    HStack(spacing: 12) {
                        Image(systemName: snapshot.reading.symbolName)
                            .font(.title3)
                            .foregroundStyle(snapshot.reading.isCharging ? .green : .primary)
                        VStack(alignment: .leading, spacing: 2) {
                            Text("\(snapshot.reading.levelText) · \(snapshot.reading.wattsText)")
                                .fontWeight(.medium)
                                .monospacedDigit()
                            Text(snapshot.reading.state.capitalized)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            Text(snapshotDetail(at: index))
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        comparisonLabel(at: index)
                    }
                }
                .listStyle(.inset)
            }
        }
    }

    private var snapshotCaptureHelp: String {
        if monitor.snapshotLoadError != nil {
            return "Resolve the unreadable snapshot file before capturing a new snapshot"
        }
        if monitor.reading.percentage == nil {
            return "Waiting for a battery reading"
        }
        return "Save the current battery reading"
    }

    private func comparison(at index: Int) -> SnapshotComparison? {
        guard index > 0 else { return nil }
        return SnapshotComparison(older: monitor.snapshots[index], newer: monitor.snapshots[index - 1])
    }

    private func snapshotDetail(at index: Int) -> String {
        let date = monitor.snapshots[index].reading.capturedAt.formatted(
            .dateTime.month(.abbreviated).day().hour().minute()
        )
        guard let comparison = comparison(at: index) else { return date }
        return "\(date) · \(comparison.elapsed.formattedElapsed) to next"
    }

    @ViewBuilder
    private func comparisonLabel(at index: Int) -> some View {
        if let comparison = comparison(at: index) {
            VStack(alignment: .trailing, spacing: 2) {
                Text(comparison.percentagePointDelta.map { $0.signed(" pp") } ?? "— pp")
                    .font(.subheadline.weight(.medium))
                if let wattDelta = comparison.wattDelta {
                    Text(wattDelta.signed(" W", precision: 1))
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .monospacedDigit()
            .accessibilityElement(children: .combine)
        } else {
            Text("Baseline")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct ReadingRow: View {
    let label: String
    let value: String
    var valueColor: Color = .primary

    var body: some View {
        HStack {
            Text(label).foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .foregroundStyle(valueColor)
                .monospacedDigit()
        }
        .font(.subheadline)
    }
}

private func diagnosticColor(_ severity: CableDiagnostic.Severity) -> Color {
    switch severity {
    case .normal: .green
    case .informational: .secondary
    case .warning: .orange
    }
}

private func diagnosticSymbol(_ severity: CableDiagnostic.Severity) -> String {
    switch severity {
    case .normal: "checkmark.circle.fill"
    case .informational: "info.circle.fill"
    case .warning: "exclamationmark.triangle.fill"
    }
}

private extension View {
    func cardStyle() -> some View {
        padding(12)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

private extension PowerEvent.TintRole {
    var color: Color {
        switch self {
        case .primary: .primary
        case .secondary: .secondary
        case .blue: .blue
        case .green: .green
        case .indigo: .indigo
        case .orange: .orange
        }
    }
}

private extension TimeInterval {
    var formattedElapsed: String {
        let totalMinutes = max(0, Int(self / 60))
        if totalMinutes < 60 { return "\(totalMinutes)m" }
        let hours = totalMinutes / 60
        let minutes = totalMinutes % 60
        if hours < 24 { return minutes == 0 ? "\(hours)h" : "\(hours)h \(minutes)m" }
        let days = hours / 24
        let remainingHours = hours % 24
        return remainingHours == 0 ? "\(days)d" : "\(days)d \(remainingHours)h"
    }
}

private extension Date {
    var relativeDescription: String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: self, relativeTo: Date())
    }
}

private extension BinaryInteger {
    func signed(_ suffix: String) -> String {
        self > 0 ? "+\(self)\(suffix)" : "\(self)\(suffix)"
    }
}

private extension Double {
    func signed(_ suffix: String, precision: Int) -> String {
        String(format: "%+.*f%@", precision, self, suffix)
    }
}
