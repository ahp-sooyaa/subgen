import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var store: JobStore
    @State private var selection: UUID?
    @State private var showNew = false

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                ForEach(store.jobs) { job in
                    JobRow(job: job, progress: store.progress[job.id]).tag(job.id)
                }
            }
            .navigationSplitViewColumnWidth(min: 240, ideal: 280)
            .toolbar {
                Button { showNew = true } label: { Label("New Job", systemImage: "plus") }
            }
            .overlay {
                if store.jobs.isEmpty {
                    ContentUnavailableView("No jobs", systemImage: "captions.bubble",
                                           description: Text("Add a YouTube link or a video file with +."))
                }
            }
        } detail: {
            if let id = selection, let job = store.job(id) {
                JobDetailView(job: job)
            } else {
                Text("Select a job").foregroundStyle(.secondary)
            }
        }
        .sheet(isPresented: $showNew) {
            NewJobSheet { job in
                store.add(job)
                selection = job.id
            }
        }
    }
}

struct JobRow: View {
    let job: Job
    let progress: JobProgress?

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: job.status.symbol)
                .foregroundStyle(job.status == .failed ? .red : job.status == .done ? .green : .secondary)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(job.displayName).lineLimit(1)
                HStack(spacing: 6) {
                    Text(job.mode.short)
                    Text("·")
                    if job.status == .running || job.status == .paused, let p = progress {
                        Text("\(Int(p.overall(job.mode) * 100))%")
                        if let s = p.current { Text(stageLabel(s)) }
                    } else {
                        Text(job.status.label)
                    }
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            }
        }
        .padding(.vertical, 2)
    }
}
