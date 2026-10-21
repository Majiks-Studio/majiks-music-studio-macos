import SwiftUI
import Charts

// MARK: - Dashboard Sub-Section

enum DashboardSubSection: String, CaseIterable {
    case sales = "Sales"
    case earnings = "Earnings"
    case payouts = "Payouts"
}

// MARK: - Dashboard View (Earnings)

struct DashboardView: View {
    @EnvironmentObject var publisherStore: PublisherStore
    @EnvironmentObject var backend: BackendViewModel

    @State private var dashboardLoaded = false
    @State private var dashboardSubSection: DashboardSubSection = .earnings
    @State private var salesPeriod: String = "month"
    @State private var earningsTimeRange: String = "6m"
    @State private var showDMCASheet = false

    var body: some View {
        ScrollView {
            VStack(spacing: 16) {
                // Summary cards
                summaryCards

                Divider()

                // Sub-section picker
                Picker("View", selection: $dashboardSubSection) {
                    ForEach(DashboardSubSection.allCases, id: \.self) { section in
                        Text(section.rawValue).tag(section)
                    }
                }
                .pickerStyle(.segmented)
                .help("Switch between Sales, Earnings, and Payouts views")

                switch dashboardSubSection {
                case .sales:
                    dashboardSalesView
                case .earnings:
                    dashboardEarningsView
                case .payouts:
                    dashboardPayoutsView
                }

                Divider()

                HStack {
                    Button {
                        showDMCASheet = true
                    } label: {
                        Label("Report Infringement", systemImage: "exclamationmark.shield")
                    }
                    .buttonStyle(.bordered)
                    .help("File a DMCA infringement report")

                    Spacer()

                    Button {
                        Task { await publisherStore.fetchDashboardData(backend: backend) }
                    } label: {
                        Label("Refresh", systemImage: "arrow.clockwise")
                    }
                    .disabled(publisherStore.dashboardLoading)
                    .help("Refresh dashboard data")
                }
            }
            .padding()
        }
        .onAppear {
            if !dashboardLoaded {
                dashboardLoaded = true
                Task { await publisherStore.fetchDashboardData(backend: backend) }
            }
        }
        .sheet(isPresented: $showDMCASheet) {
            DMCAReportSheet { trackId, reason, claimantName, claimantEmail in
                Task {
                    guard let auth = await publisherStore.validAuthContext() else { return }
                    do {
                        _ = try await backend.fileDMCAClaim(
                            keycloakId: auth.keycloakId, trackId: trackId,
                            reason: reason, claimantName: claimantName,
                            claimantEmail: claimantEmail,
                            accessToken: auth.accessToken
                        )
                        ToastManager.shared.show("Infringement report filed", style: .info)
                    } catch {
                        AppLog.error("DMCA claim failed: \(error)")
                        ToastManager.shared.show("Failed to file infringement report", style: .error)
                    }
                }
            }
        }
    }

    // MARK: - Summary Cards

    @ViewBuilder
    private var summaryCards: some View {
        if let earnings = publisherStore.earningsSummary,
           let catalog = publisherStore.catalogSummary {
            HStack(spacing: 12) {
                DashboardCard(
                    title: "Total Earned",
                    value: String(format: "$%.2f", earnings.totalEarned),
                    icon: "dollarsign.circle.fill",
                    color: .green
                )
                DashboardCard(
                    title: "This Month",
                    value: String(format: "$%.2f", earnings.thisMonth),
                    icon: "calendar",
                    color: .blue
                )
                DashboardCard(
                    title: "Pending",
                    value: String(format: "$%.2f", earnings.pendingPayouts),
                    icon: "clock.fill",
                    color: .orange
                )
                DashboardCard(
                    title: "Tracks Published",
                    value: "\(catalog.trackCount)",
                    icon: "music.note.list",
                    color: Color(red: 0.545, green: 0.361, blue: 0.965)
                )
            }
        } else if publisherStore.dashboardLoading {
            HStack(spacing: 12) {
                ForEach(0..<4, id: \.self) { _ in
                    DashboardCard(title: "Loading...", value: "--", icon: "ellipsis", color: .gray)
                }
            }
        }
    }

    // MARK: - Sales Sub-View

    private var dashboardSalesView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Recent Sales")
                    .font(.headline)
                Spacer()
                Picker("Period", selection: $salesPeriod) {
                    Text("Week").tag("week")
                    Text("Month").tag("month")
                    Text("Year").tag("year")
                    Text("All").tag("all")
                }
                .frame(maxWidth: 150)
                .help("Filter sales by time period")
                .onChange(of: salesPeriod) { _, period in
                    Task { await publisherStore.fetchSalesHistory(backend: backend, period: period) }
                }
            }

            if let summary = publisherStore.salesSummary {
                HStack(spacing: 16) {
                    Text("Total: \(summary.totalSales) sales")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                    Text(String(format: "Revenue: $%.2f", summary.totalRevenue))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Top tracks
            if let topTracks = publisherStore.salesSummary?.topTracks, !topTracks.isEmpty {
                VStack(alignment: .leading, spacing: 10) {
                    Text("Top Tracks")
                        .font(.headline)

                    ForEach(Array(topTracks.prefix(10).enumerated()), id: \.element.id) { index, track in
                        HStack(spacing: 12) {
                            ZStack {
                                Circle()
                                    .fill(Color(red: 0.545, green: 0.361, blue: 0.965).opacity(0.12))
                                    .frame(width: 28, height: 28)
                                Text("\(index + 1)")
                                    .font(.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(Color(red: 0.545, green: 0.361, blue: 0.965))
                            }

                            VStack(alignment: .leading, spacing: 2) {
                                Text(track.title)
                                    .font(.subheadline)
                                    .lineLimit(1)
                                Text("\(track.sales) sales")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            Spacer()

                            Text(String(format: "$%.2f", track.revenue))
                                .font(.subheadline)
                                .fontWeight(.medium)
                                .foregroundStyle(.green)
                        }
                        .padding(.vertical, 2)
                    }
                }
                .padding(.top, 4)
            }

            // Transactions
            if publisherStore.salesTransactions.isEmpty {
                Text("No sales data available")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(publisherStore.salesTransactions) { sale in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(sale.trackTitle)
                                .font(.body)
                                .lineLimit(1)
                            Text(sale.date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        if !sale.buyer.isEmpty {
                            Text(sale.buyer)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Text(String(format: "$%.2f", sale.amount))
                            .font(.body)
                            .fontWeight(.medium)
                            .foregroundStyle(.green)
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
    }

    // MARK: - Earnings Sub-View

    private var dashboardEarningsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center) {
                Text("Earnings Overview")
                    .font(.headline)
                Spacer()
                Picker("Time Range", selection: $earningsTimeRange) {
                    Text("3 Months").tag("3m")
                    Text("6 Months").tag("6m")
                    Text("1 Year").tag("1y")
                    Text("All Time").tag("all")
                }
                .frame(maxWidth: 220)
                .help("Filter earnings chart by time range")
            }

            if let earnings = publisherStore.earningsSummary {
                // Summary stats
                HStack(spacing: 24) {
                    VStack(alignment: .leading) {
                        Text("This Month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "$%.2f", earnings.thisMonth))
                            .font(.title3)
                            .fontWeight(.semibold)
                    }
                    VStack(alignment: .leading) {
                        Text("Last Month")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "$%.2f", earnings.lastMonth))
                            .font(.title3)
                    }
                    VStack(alignment: .leading) {
                        Text("Pending")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text(String(format: "$%.2f", earnings.pendingPayouts))
                            .font(.title3)
                            .foregroundStyle(.orange)
                    }
                }

                if !filteredChartData(from: earnings.chartData).isEmpty {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Monthly Earnings")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)

                        Chart {
                            ForEach(filteredChartData(from: earnings.chartData)) { month in
                                BarMark(
                                    x: .value("Month", String(month.month.suffix(3))),
                                    y: .value("Earnings", month.amount)
                                )
                                .foregroundStyle(Color(red: 0.545, green: 0.361, blue: 0.965).gradient)
                            }
                        }
                        .frame(height: 200)
                        .chartYAxis { AxisMarks(format: .currency(code: "USD")) }
                    }
                }
            } else {
                Text("No earnings data available")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            }
        }
    }

    private func filteredChartData(from chartData: [EarningsSummary.MonthlyEarning]) -> [EarningsSummary.MonthlyEarning] {
        switch earningsTimeRange {
        case "3m":
            return Array(chartData.suffix(3))
        case "6m":
            return Array(chartData.suffix(6))
        case "1y":
            return Array(chartData.suffix(12))
        default:
            return chartData
        }
    }

    // MARK: - Payouts Sub-View

    private var dashboardPayoutsView: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Payout History")
                    .font(.headline)
                Spacer()
                Button {
                    Task { await publisherStore.fetchPayoutHistory(backend: backend) }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }
                .controlSize(.small)
                .help("Refresh payout history")
            }

            if publisherStore.payoutHistory.isEmpty {
                Text("No payouts yet")
                    .font(.body)
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 20)
            } else {
                ForEach(publisherStore.payoutHistory) { payout in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(String(format: "$%.2f", payout.amount))
                                .font(.body)
                                .fontWeight(.medium)
                            Text(payout.date)
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                        }
                        Spacer()
                        Text(payout.status)
                            .font(.caption)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 2)
                            .background(payoutStatusColor(payout.status).opacity(0.15))
                            .foregroundStyle(payoutStatusColor(payout.status))
                            .clipShape(Capsule())
                    }
                    .padding(.vertical, 4)
                    Divider()
                }
            }
        }
        .onAppear {
            if publisherStore.payoutHistory.isEmpty {
                Task { await publisherStore.fetchPayoutHistory(backend: backend) }
            }
        }
    }

    // MARK: - Helpers

    private func payoutStatusColor(_ status: String) -> Color {
        switch status.lowercased() {
        case "completed", "paid": return .green
        case "pending": return .orange
        case "failed": return .red
        default: return .secondary
        }
    }
}

// MARK: - Dashboard Summary Card

struct DashboardCard: View {
    let title: String
    let value: String
    let icon: String
    let color: Color

    var body: some View {
        VStack(spacing: 6) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(color)
            Text(value)
                .font(.title3)
                .fontWeight(.bold)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity)
        .padding(12)
        .background(color.opacity(0.08))
        .cornerRadius(10)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(title): \(value)")
    }
}

// MARK: - DMCA Report Sheet

struct DMCAReportSheet: View {
    @Environment(\.dismiss) private var dismiss
    let onSubmit: (String, String, String, String) -> Void

    @State private var trackId: String = ""
    @State private var reason: String = ""
    @State private var claimantName: String = ""
    @State private var claimantEmail: String = ""

    var body: some View {
        VStack(spacing: 16) {
            Text("Report Infringement")
                .font(.title2)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 12) {
                LabeledContent("Track ID") {
                    TextField("UUID of the infringing track", text: $trackId)
                        .textFieldStyle(.roundedBorder)
                        .font(.system(.body, design: .monospaced))
                }
                LabeledContent("Your Name") {
                    TextField("Legal name", text: $claimantName)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Your Email") {
                    TextField("your@email.com", text: $claimantEmail)
                        .textFieldStyle(.roundedBorder)
                }
                LabeledContent("Reason") {
                    TextField("e.g. Unauthorized use of my original work", text: $reason)
                        .textFieldStyle(.roundedBorder)
                }
            }
            .padding()

            Text("By submitting, you assert that you are the rights holder or authorized to act on their behalf.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .help("Cancel infringement report")
                Spacer()
                Button("Submit Report") {
                    onSubmit(trackId, reason, claimantName, claimantEmail)
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
                .buttonStyle(.borderedProminent)
                .disabled(trackId.isEmpty || reason.isEmpty || claimantName.isEmpty || claimantEmail.isEmpty)
                .help("Submit the DMCA infringement report")
            }
            .padding(.horizontal)
        }
        .padding()
        .frame(width: 500, height: 420)
    }
}
