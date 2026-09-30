import SwiftUI
import UniformTypeIdentifiers

/// One-time setup checklist. Shown until the first screenshot arrives, and from the Setup button after that.
struct SetupView: View {
    @EnvironmentObject private var store: Store
    @State private var showingFolderPicker = false
    @State private var pendingLimitGB: Int?  // a lower limit waiting for the user to confirm

    /// Raising the limit applies at once. Lowering it below what's already used removes files, so it asks first.
    private var storageLimit: Binding<Int> {
        Binding(
            get: { store.storageLimitGB },
            set: { newLimit in
                if Int64(newLimit) * 1_000_000_000 < store.storageUsed {
                    pendingLimitGB = newLimit
                } else {
                    store.storageLimitGB = newLimit
                }
            }
        )
    }

    /// The Goldie Snap shortcut. `level` is the indent: 1 = inside the Repeat, 2 = inside the If.
    /// The If stops each run at 11:50 PM, so a mid-day Start or Restart never overlaps the midnight run.
    private let shortcutActions: [(text: String, level: Int)] = [
        ("**Repeat** 288 times", 0),
        ("**Format Date** → Current Date, Date Format **Custom**, format `HH:mm`", 1),
        ("**If** → Formatted Date **begins with** `23:5`", 1),
        ("**Stop This Shortcut** (between If and Otherwise; leave Otherwise empty)", 2),
        ("**Open App** → Find My (below **End If**)", 1),
        ("**Wait** 3 seconds", 1),
        ("**Take Screenshot**", 1),
        ("**Convert Image** → JPEG, quality about 50%", 1),
        ("**Save File** → turn off **Ask Where to Save**, tap the folder, go to **On My iPad**, tap **New Folder**, name it **Goldie**, and choose it", 1),
        ("**Nothing**", 1),
        ("**Wait** 295 seconds", 1),
    ]

    var body: some View {
        List {
            Section {
                VStack(spacing: 12) {
                    Image(systemName: "pawprint.fill")
                        .font(.system(size: 36, weight: .semibold))
                        .foregroundStyle(.white)
                        .frame(width: 76, height: 76)
                        .background(
                            LinearGradient(colors: [.orange, .red.opacity(0.85)], startPoint: .top, endPoint: .bottom),
                            in: RoundedRectangle(cornerRadius: 18)
                        )
                    Text("Welcome to Goldie Tracker")
                        .font(.title2.weight(.bold))
                    Text("Five one-time steps. Tip: open Shortcuts beside this app in Split View to follow along.")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
            }

            Section {
                Text("Settings → Display & Brightness → Auto-Lock → **Never**. Keep the iPad plugged in so the screen stays on.")
            } header: {
                StepHeader(number: 1, title: "Keep the Screen On")
            }

            Section {
                Text("In Shortcuts, tap **+** and name it **Goldie Snap**. Add these actions, searching for each one at the bottom. Actions 2–11 must go **inside** the Repeat. Drag them in if they land below it.")
                ForEach(Array(shortcutActions.enumerated()), id: \.offset) { index, action in
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text("\(index + 1)")
                            .font(.caption.weight(.bold))
                            .monospacedDigit()
                            .foregroundStyle(.tint)
                            .frame(width: 22, height: 22)
                            .background(.tint.opacity(0.15), in: Circle())
                        Text(LocalizedStringKey(action.text))
                    }
                    .padding(.leading, CGFloat(action.level) * 24)
                }
                Link(destination: openShortcutsURL) {
                    Label("Open Shortcuts", systemImage: "arrow.up.forward.app")
                }
            } header: {
                StepHeader(number: 2, title: "Create the Goldie Snap Shortcut")
            }

            Section {
                Text("In Shortcuts: **Automation** tab → **+** → **Time of Day** → **12:00 AM**, **Daily** → **Run Immediately** → **Next** → **Goldie Snap**.")
            } header: {
                StepHeader(number: 3, title: "Run It Every Day")
            }

            Section {
                if let folder = store.folderURL {
                    Label(folder.lastPathComponent, systemImage: "folder.fill")
                }
                Button(store.folderURL == nil ? "Choose Folder…" : "Change Folder…") {
                    showingFolderPicker = true
                }
            } header: {
                StepHeader(number: 4, title: "Choose the Goldie Folder", done: store.folderURL != nil)
            }

            Section {
                Text("Tap Start. When Find My opens, tap **Items → Goldie** and leave it there. (Between 11:50 PM and midnight the shortcut stops right away and the midnight run takes over.)")
                Link(destination: runGoldieSnapURL) {
                    Label("Start Goldie Snap", systemImage: "play.fill")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .listRowInsets(EdgeInsets(top: 12, leading: 16, bottom: 12, trailing: 16))

                if let last = store.lastScreenshotDate {
                    Label("Working. Last screenshot \(last, style: .relative) ago.", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Label("Waiting for the first screenshot…", systemImage: "hourglass")
                        .foregroundStyle(.secondary)
                }
            } header: {
                StepHeader(number: 5, title: "Start Tracking", done: store.lastScreenshotDate != nil)
            }

            Section {
                Picker("Storage Limit", selection: storageLimit) {
                    ForEach(StorageGuard.limitOptionsGB, id: \.self) { gigabytes in
                        Text("\(gigabytes) GB").tag(gigabytes)
                    }
                }
            } header: {
                Text("Storage")
            } footer: {
                Text("Goldie's screenshots and animations are kept under this limit, and at least 2 GB is always left free on the iPad. When full, the oldest screenshots are removed first (their animations are kept), then the oldest animations. Today's screenshots are never removed.")
            }
        }
        .listStyle(.insetGrouped)
        .navigationTitle("Setup")
        .navigationBarTitleDisplayMode(.inline)
        .fileImporter(isPresented: $showingFolderPicker, allowedContentTypes: [.folder]) { result in
            if case .success(let url) = result {
                store.setFolder(url)
            }
        }
        .confirmationDialog(
            "Lower the Storage Limit?",
            isPresented: Binding(get: { pendingLimitGB != nil }, set: { if !$0 { pendingLimitGB = nil } }),
            titleVisibility: .visible,
            presenting: pendingLimitGB
        ) { limit in
            Button("Lower to \(limit) GB", role: .destructive) {
                store.storageLimitGB = limit
            }
        } message: { _ in
            Text("Goldie's files are over that limit, so the oldest screenshots (and, if needed, the oldest animations) will be removed now. This can't be undone.")
        }
    }
}

/// Numbered step title that turns into a green checkmark once the step is done.
struct StepHeader: View {
    let number: Int
    let title: String
    var done = false

    var body: some View {
        Label {
            Text(title)
        } icon: {
            Image(systemName: done ? "checkmark.circle.fill" : "\(number).circle.fill")
                .foregroundStyle(done ? Color.green : Color.accentColor)
        }
        .font(.headline)
        .foregroundStyle(.primary)
        .textCase(nil)
    }
}
