import SwiftUI

// Workouts from every source: the ring, Apple Health (an Apple Watch), and the ones
// the wearer adds. The list is `Summary.mergedWorkouts`.

struct WorkoutRow: View {
    let w: WorkoutEntry
    var showDay = false
    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: activitySymbol(w.label))
                .font(.body.weight(.medium))
                .foregroundStyle(Theme.activity)
                .frame(width: 36, height: 36)
                .background(Theme.activity.opacity(0.14), in: Circle())
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(actLabel(w.label)).font(.body.weight(.medium))
                    .foregroundStyle(.primary)
                HStack(spacing: 4) {
                    Image(systemName: w.sourceIcon).font(.caption2)
                    Text(showDay ? "\(Fmt.dayLabel(w.day)), \(Fmt.clock(w.startHM))" : Fmt.clock(w.startHM))
                }
                .font(.subheadline).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text("\(Int(w.duration_min)) min").font(.subheadline).monospacedDigit()
                    .foregroundStyle(.primary)
                if let hr = w.avg_hr {
                    Text("\(Int(hr)) bpm").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
            }
        }
        .frame(minHeight: 44)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(actLabel(w.label)), \(Int(w.duration_min)) minutes, from \(w.source_name)")
    }
}

struct WorkoutsView: View {
    let s: Summary
    let onChanged: () -> Void
    @State private var adding = false

    var body: some View {
        let all = s.mergedWorkouts
        let days = Array(Set(all.map(\.day))).sorted(by: >)
        List {
            Section {
                NavigationLink(value: Route.live(.workout)) {
                    Label("Start a Workout with Live Heart Rate", systemImage: "figure.run")
                }
                Button { adding = true } label: {
                    Label("Add a Workout", systemImage: "plus.circle")
                }
            }
            if all.isEmpty {
                Section {
                    Text("No workouts yet. The ring finds activity of 15 minutes or more. You can also add a workout or turn on Apple Health workouts in Settings.")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
            }
            ForEach(days, id: \.self) { day in
                Section(Fmt.dayLabel(day)) {
                    ForEach(all.filter { $0.day == day }) { w in
                        NavigationLink(value: Route.workout(w.id)) { WorkoutRow(w: w) }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Workouts")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(isPresented: $adding) {
            AddWorkoutView { onChanged() }
        }
    }
}

struct WorkoutDetailView: View {
    let w: WorkoutEntry
    let onChanged: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var confirmDelete = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 12) {
                    CardHeader(title: actLabel(w.label), icon: activitySymbol(w.label), tint: Theme.activity,
                               detail: Fmt.dayLabel(w.day))
                    BigValue(parts: Fmt.minutes(w.duration_min), style: .largeTitle)
                    Text("\(Fmt.clock(w.startHM)) – \(Fmt.clock(String(w.end.suffix(5))))")
                        .font(.subheadline).foregroundStyle(.secondary)
                }
                .card()

                VStack(spacing: 10) {
                    if let kcal = w.active_kcal {
                        StatRow(label: "Active energy", value: "\(Fmt.number(kcal)) kcal")
                        Divider()
                    }
                    if let d = w.distance_m {
                        StatRow(label: "Distance", value: Fmt.distance(meters: d))
                        Divider()
                    }
                    if let hr = w.avg_hr {
                        StatRow(label: "Average heart rate", value: "\(Int(hr)) bpm")
                        Divider()
                    }
                    if let hr = w.max_hr {
                        StatRow(label: "Highest heart rate", value: "\(Int(hr)) bpm")
                        Divider()
                    }
                    StatRow(label: "Source", value: w.source_name)
                }
                .card()

                if let note = w.note, !note.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("Note").font(.headline)
                        Text(note).font(.subheadline).foregroundStyle(.secondary)
                    }
                    .card()
                }

                Text(sourceText).font(.footnote).foregroundStyle(.secondary).padding(.horizontal, 4)

                if w.journalID != nil {
                    Button("Delete Workout", role: .destructive) { confirmDelete = true }
                        .frame(maxWidth: .infinity)
                        .padding(.top, 8)
                        .confirmationDialog("Delete this workout?", isPresented: $confirmDelete, titleVisibility: .visible) {
                            Button("Delete", role: .destructive) {
                                if let id = w.journalID, JournalStore.apply(["op": "remove_workout", "id": id]) != nil {
                                    onChanged()
                                    dismiss()
                                }
                            }
                        }
                }
            }
            .padding(.horizontal, Theme.gutter)
            .padding(.bottom, 32)
        }
        .background(Color(.systemGroupedBackground))
        .navigationTitle("Workout")
        .navigationBarTitleDisplayMode(.inline)
    }

    private var sourceText: String {
        switch w.source {
        case "health": return "From Apple Health. When it reports more active energy than the ring measured in this time, the day's energy and Activity score get the difference."
        case "manual": return "You added this workout. Without an energy value, the app estimates it from the type of activity and your weight."
        case "ring": return "Found by the activity model on this iPhone from the ring's movement data."
        default: return "Found from the ring's movement data: 15 minutes or more at moderate effort or harder. The ring cannot tell the type of activity."
        }
    }
}

struct AddWorkoutView: View {
    let onSaved: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var label = "Running"
    @State private var start = Date().addingTimeInterval(-3600)
    @State private var minutes = 30.0
    @State private var kcal: Double?
    @State private var note = ""
    @State private var error: String?

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Activity", selection: $label) {
                        ForEach(LiveHeartView.workoutLabels, id: \.self) { Text($0).tag($0) }
                    }
                    DatePicker("Start", selection: $start, in: ...Date())
                    LabeledContent("Duration") {
                        HStack(spacing: 4) {
                            TextField("Duration", value: $minutes, format: .number.precision(.fractionLength(0)))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 80)
                            Text("min").foregroundStyle(.secondary)
                        }
                    }
                }
                Section {
                    LabeledContent("Active energy") {
                        HStack(spacing: 4) {
                            TextField("Optional", value: $kcal, format: .number.precision(.fractionLength(0)))
                                .keyboardType(.numberPad)
                                .multilineTextAlignment(.trailing)
                                .frame(maxWidth: 100)
                            Text("kcal").foregroundStyle(.secondary)
                        }
                    }
                    TextField("Note", text: $note, axis: .vertical)
                } footer: {
                    Text("Without an energy value, the app estimates it from the activity and your weight.")
                }
                if let error {
                    Section { Text(error).foregroundStyle(Theme.alert).font(.footnote) }
                }
            }
            .navigationTitle("Add Workout")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { save() }.disabled(minutes < 1)
                }
            }
        }
    }

    private func save() {
        var op: [String: Any] = ["op": "add_workout", "start_unix": Int(start.timeIntervalSince1970),
                                 "duration_min": minutes, "label": label, "note": note]
        if let kcal, kcal > 0 { op["active_kcal"] = kcal }
        if JournalStore.apply(op) != nil {
            onSaved()
            dismiss()
        } else {
            error = "The workout was not saved. Check the duration (1 to 1440 minutes)."
        }
    }
}
