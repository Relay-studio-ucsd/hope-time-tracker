import HopeCore
import SwiftUI

/// Today: the total, the timer, and today's records. Deliberately minimal for stage 8 — no ring, no charts.
struct TodayView: View {
    @Environment(AppModel.self) private var model
    @State private var showPicker = false

    var body: some View {
        let store = model.store
        let _ = store.revision  // recompute on every change, local or pulled
        let timer = store.timerState()
        NavigationStack {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let now = Int64(context.date.timeIntervalSince1970 * 1000)
                // The day another tab opened (`AppModel.openDay`), else today as lived (rebuild-plan 10 E).
                let day = model.viewedDay.flatMap { DayRules.date(of: $0) } ?? store.livedToday(now: now)
                let today = store.daySummary(on: day, now: now)
                List {
                    Section {
                        VStack(alignment: .leading, spacing: 4) {
                            DurationText(ms: today.totalMs, size: 40)
                            Text("Tracked").font(.subheadline).foregroundStyle(.secondary)
                        }
                        .padding(.vertical, 8)
                    }
                    Section { TimerSection(timer: timer, now: now, showPicker: $showPicker) }
                    Section("Today") {
                        if today.entries.isEmpty {
                            Text("Nothing tracked yet").foregroundStyle(.tertiary)
                        }
                        ForEach(today.entries) { EntryRow(entry: $0) }
                    }
                }
            }
            .navigationTitle("Today")
            .refreshable { model.sync.syncNow() }
        }
        .sheet(isPresented: $showPicker) {
            ActivityPickerSheet { id in
                model.start(id)
                showPicker = false
            }
        }
        .alert(
            "Something went wrong", isPresented: Binding(get: { model.failure != nil }, set: { if !$0 { model.failure = nil } })
        ) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(verbatim: model.failure ?? "")
        }
    }
}

/// Running: name, ticking time, Pause / Stop. Paused: Resume / Stop. Idle: Start.
private struct TimerSection: View {
    @Environment(AppModel.self) private var model
    var timer: TimerState
    var now: Int64
    @Binding var showPicker: Bool

    var body: some View {
        if let session = timer.running ?? timer.paused {
            let running = timer.running != nil
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 10) {
                    ActivityDot(color: model.store.color(activityId: session.activityId))
                    Text(verbatim: model.store.displayName(activityId: session.activityId) ?? String(localized: "Unknown activity"))
                        .font(.headline)
                    Spacer()
                    if !running { Text("Paused").font(.subheadline).foregroundStyle(.secondary) }
                }
                Text(verbatim: DurationFormat.elapsed(model.store.chainDuration(endingWith: session, now: now)))
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(running ? .primary : .secondary)
                HStack(spacing: 12) {
                    if running {
                        Button { model.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                    } else {
                        Button { model.resume() } label: { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
                    }
                    Button { model.stop() } label: { Label("Stop", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                }
                .buttonStyle(.bordered)
                .controlSize(.large)
                .tint(.primary)
                Button("Start Something Else") { showPicker = true }
                    .font(.subheadline)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }
            .padding(.vertical, 6)
        } else {
            Button { showPicker = true } label: {
                Label("Start Timer", systemImage: "play.fill").frame(maxWidth: .infinity)
            }
            .buttonStyle(.bordered)
            .controlSize(.large)
            .tint(.primary)
        }
    }
}

private struct EntryRow: View {
    var entry: DayEntry

    var body: some View {
        HStack(spacing: 10) {
            ActivityDot(color: entry.color)
            VStack(alignment: .leading, spacing: 2) {
                Text(verbatim: entry.title ?? String(localized: "Unknown activity"))
                    .foregroundStyle(entry.title == nil ? .secondary : .primary)
                Text(verbatim: "\(Format.clock(entry.startMs))–\(entry.endMs.map(Format.clock) ?? String(localized: "now"))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer()
            Text(verbatim: Format.duration(entry.durationMs))
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// The picker in a sheet: top-level list, drill into sub-activities, add an activity.
struct ActivityPickerSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    var onPick: (String) -> Void
    @State private var showNew = false

    var body: some View {
        let _ = model.store.revision
        let tree = model.store.activityTree()
        NavigationStack {
            List {
                if tree.isEmpty {
                    Text("No activities yet").foregroundStyle(.tertiary)
                }
                ActivityRows(tree: tree, onPick: onPick)
                Button { showNew = true } label: {
                    Label("New Activity", systemImage: "plus")
                }
            }
            .navigationTitle("Start Timer")
            .navigationBarTitleDisplayMode(.inline)
            .navigationDestination(for: ActivityNodeRoute.self) { route in
                if let node = tree.first(where: { $0.id == route.id }) {
                    ChildActivityList(node: node, onPick: onPick)
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
            }
            .sheet(isPresented: $showNew) {
                NavigationStack {
                    NewActivityView { name, color in model.createActivity(name: name, color: color) }
                }
            }
        }
    }
}
