import SwiftUI

/// Shown once, before the first pairing. Pocket pairs with one app at a time, so it must be reset first.
struct OnboardingView: View {
    @Environment(PocketDeviceController.self) private var pocket
    var finish: () -> Void
    @State private var step = Step.question

    enum Step { case question, reset, pair }

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 16) {
                switch step {
                case .question: question
                case .reset: reset
                case .pair: pair
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Not now") { pocket.stopScan(); finish() } }
            }
        }
        .onChange(of: pocket.authenticated) { _, authenticated in if authenticated { finish() } }
        .interactiveDismissDisabled()
    }

    private var question: some View {
        Group {
            Text("Is your Pocket reset?").font(.largeTitle.bold())
            Text("Pocket pairs with one app at a time. A reset unpairs it from the Pocket app.").foregroundStyle(.secondary)
            Spacer()
            Button { step = .pair } label: { Text("Yes, it’s reset").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
            Button { step = .reset } label: { Text("No").frame(maxWidth: .infinity) }
                .buttonStyle(.bordered).controlSize(.large)
        }
    }

    private var reset: some View {
        Group {
            Text("Reset your Pocket").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 14) {
                Text("1. Close the Pocket app on your phone.")
                Text("2. Triple-click the side button. The light blinks red.")
                Text("3. Press and hold the button until the red blinking stops.")
                Text("4. Wait until the light pulses blue.")
            }
            Spacer()
            Button { step = .pair } label: { Text("Continue to pairing").frame(maxWidth: .infinity) }
                .buttonStyle(.borderedProminent).controlSize(.large)
        }
    }

    private var pair: some View {
        Group {
            Text("Pair your Pocket").font(.largeTitle.bold())
            Text(pocket.status).foregroundStyle(.secondary)
            if let error = pocket.error { Text(error).font(.callout).foregroundStyle(.orange) }
            ForEach(pocket.devices) { device in
                Button { pocket.pair(device) } label: {
                    HStack {
                        Text(device.name)
                        Spacer()
                        if pocket.busy { ProgressView() } else { Text("Pair").fontWeight(.semibold) }
                    }
                    .padding(16)
                    .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 16))
                }
                .buttonStyle(.plain).disabled(pocket.busy)
            }
            Spacer()
            if !pocket.scanning && !pocket.busy {
                Button { pocket.scan() } label: { Text("Search again").frame(maxWidth: .infinity) }
                    .buttonStyle(.bordered).controlSize(.large)
            }
        }
        .onAppear { pocket.scan() }
    }
}
