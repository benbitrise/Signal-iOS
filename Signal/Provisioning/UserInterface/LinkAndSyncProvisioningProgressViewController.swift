//
// Copyright 2024 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import Lottie
import SwiftUI
import SignalUI
import SignalServiceKit

// MARK: View Model

class LinkAndSyncSecondaryProgressViewModel: ObservableObject {
    @Published private(set) var taskProgress: Float = 0
    @Published private(set) var canBeCancelled: Bool = false
    @Published var isIndeterminate = true
    @Published var linkNSyncTask: Task<Void, Error>?
    @Published var didTapCancel: Bool = false

#if DEBUG
    @Published var progressSourceLabel: String?
#endif

    var progress: Float {
        didTapCancel ? 0 : taskProgress
    }

    func updateProgress(_ progress: OWSProgress) {
        objectWillChange.send()

#if DEBUG
        progressSourceLabel = progress.currentSourceLabel
#endif

        let canBeCancelled: Bool
        if let label = progress.currentSourceLabel {
            canBeCancelled = label != SecondaryLinkNSyncProgressPhase.waitingForBackup.rawValue
        } else {
            canBeCancelled = false
        }

        guard !didTapCancel else { return }

        if progress.completedUnitCount > SecondaryLinkNSyncProgressPhase.waitingForBackup.percentOfTotalProgress {
            isIndeterminate = false
        }
        withAnimation(.smooth) {
            self.taskProgress = progress.percentComplete
        }

        self.canBeCancelled = canBeCancelled
    }

    func cancel(task: Task<Void, Error>) {
        task.cancel()
        withAnimation(.smooth(duration: 0.2)) {
            didTapCancel = true
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) { [weak self] in
            self!.isIndeterminate = true
        }
    }
}

// MARK: Hosting Controller

class LinkAndSyncProvisioningProgressViewController: HostingController<LinkAndSyncProvisioningProgressView> {
    fileprivate var viewModel: LinkAndSyncSecondaryProgressViewModel

    var linkNSyncTask: Task<Void, Error>? {
        get { viewModel.linkNSyncTask }
        set {
            viewModel.linkNSyncTask = newValue
            viewModel.didTapCancel = newValue?.isCancelled ?? false
        }
    }

    init(viewModel: LinkAndSyncSecondaryProgressViewModel) {
        self.viewModel = viewModel
        super.init(wrappedView: LinkAndSyncProvisioningProgressView(viewModel: viewModel))
        self.modalPresentationStyle = .fullScreen
        self.modalTransitionStyle = .crossDissolve
    }
}

// MARK: SwiftUI View

struct LinkAndSyncProvisioningProgressView: View {

    @ObservedObject fileprivate var viewModel: LinkAndSyncSecondaryProgressViewModel

    @State private var indeterminateProgressShouldShow = false
    private var showIndeterminateProgress: Bool {
        viewModel.isIndeterminate || indeterminateProgressShouldShow
    }
    private var loopMode: LottieLoopMode {
        viewModel.isIndeterminate ? .loop : .playOnce
    }
    private var progressToShow: Float {
        indeterminateProgressShouldShow ? 0 : viewModel.progress
    }

    private var subtitle: String {
        if viewModel.didTapCancel {
            OWSLocalizedString(
                "LINK_NEW_DEVICE_SYNC_PROGRESS_TILE_CANCELLING",
                comment: "Title for a progress modal that would be indicating the sync progress while it's cancelling that sync"
            )
        } else if indeterminateProgressShouldShow && viewModel.progress < 0.95 {
            OWSLocalizedString(
                "LINKING_SYNCING_PREPARING_TO_DOWNLOAD",
                comment: "Progress label when the message loading has not yet started during the device linking process"
            )
        } else if viewModel.progress < 0.95 {
            String(
                format: OWSLocalizedString(
                    "LINK_NEW_DEVICE_SYNC_PROGRESS_PERCENT",
                    comment: "On a progress modal indicating the percent complete the sync process is. Embeds {{ formatted percentage }}"
                ),
                progressToShow.formatted(.percent.precision(.fractionLength(0)))
            )
        } else {
            OWSLocalizedString(
                "LINKING_SYNCING_FINALIZING",
                comment: "Progress label when the message loading has nearly completed during the device linking process"
            )
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer()
            Text(OWSLocalizedString(
                "LINKING_SYNCING_MESSAGES_TITLE",
                comment: "Title shown when loading messages during linking process"
            ))
            .font(.title2.bold())
            .foregroundStyle(Color.Signal.label)
            .padding(.bottom, 24)

            ZStack {
                LinearProgressView(progress: progressToShow)
                    .animation(.smooth, value: indeterminateProgressShouldShow)

                if showIndeterminateProgress {
                    LottieView(animation: .named("linear_indeterminate"))
                        .playing(loopMode: loopMode)
                        .animationDidFinish { completed in
                            guard completed else { return }
                            indeterminateProgressShouldShow = false
                        }
                        .onAppear {
                            indeterminateProgressShouldShow = true
                        }
                }
            }
            .padding(.bottom, 12)
            .onChange(of: viewModel.isIndeterminate) { isIndeterimate in
                // See LinkAndSyncProgressModal.swift
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    self.indeterminateProgressShouldShow = false
                }
            }

            Group {
                Text(verbatim: subtitle)
                    .font(.footnote.monospacedDigit())
                    .padding(.bottom, 22)
                    .animation(.none, value: subtitle)

                Text(OWSLocalizedString(
                    "LINKING_SYNCING_TIMING_INFO",
                    comment: "Label below the progress bar when loading messages during linking process"
                ))
                .font(.subheadline)
            }
            .foregroundStyle(Color.Signal.secondaryLabel)

#if DEBUG
            Text("DEBUG: " + (viewModel.progressSourceLabel ?? "none") + "\n\(viewModel.taskProgress)")
                .padding(.top)
                .foregroundStyle(Color.Signal.quaternaryLabel)
                .animation(.none, value: viewModel.progressSourceLabel)
                .animation(.none, value: viewModel.taskProgress)
#endif

            Spacer()

            if let linkNSyncTask = viewModel.linkNSyncTask {
                Button(CommonStrings.cancelButton) {
                    viewModel.cancel(task: linkNSyncTask)
                }
                .opacity(viewModel.canBeCancelled ? 1 : 0)
                .disabled(!viewModel.canBeCancelled || viewModel.didTapCancel)
                .padding(.bottom, 56)
            }

            Group {
                SignalSymbol.lock.text(dynamicTypeBaseSize: 20)
                    .padding(.bottom, 6)

                Text(OWSLocalizedString(
                    "LINKING_SYNCING_FOOTER",
                    comment: "Footer text when loading messages during linking process."
                ))
                .appendLink(CommonStrings.learnMore) {
                    UIApplication.shared.open(URL(string: "https://support.signal.org/hc/articles/360007320551")!)
                }
                .font(.footnote)
                .frame(maxWidth: 412)
            }
            .foregroundStyle(Color.Signal.secondaryLabel)
        }
        .tint(Color.Signal.accent)
        .padding()
        .multilineTextAlignment(.center)
    }

    // MARK: Linear Progress View

    private struct LinearProgressView: View {
        var progress: Float

        var body: some View {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule()
                        .foregroundStyle(Color.Signal.secondaryFill)

                    Capsule()
                        .foregroundStyle(Color.Signal.accent)
                        .frame(width: geo.size.width * CGFloat(progress))
                }
            }
            .frame(width: 360, height: 4)
        }
    }
}

// MARK: Previews

#if DEBUG
@available(iOS 17, *)
#Preview {
    let view = LinkAndSyncProvisioningProgressViewController(viewModel: LinkAndSyncSecondaryProgressViewModel())

    let progressSink = OWSProgress.createSink { progress in
        Task { @MainActor in
            view.viewModel.updateProgress(progress)
        }
    }

    let task = Task { @MainActor in
        let nonCancellableProgressSource = await progressSink.addSource(
            withLabel: SecondaryLinkNSyncProgressPhase.waitingForBackup.rawValue,
            unitCount: 10
        )
        let cancellableProgressSource = await progressSink.addSource(
            withLabel: SecondaryLinkNSyncProgressPhase.downloadingBackup.rawValue,
            unitCount: 90
        )

        try? await Task.sleep(for: .seconds(1))

        while nonCancellableProgressSource.completedUnitCount < 10 {
            nonCancellableProgressSource.incrementCompletedUnitCount(by: 1)
            try? await Task.sleep(for: .milliseconds(100))
        }

        while cancellableProgressSource.completedUnitCount < 90 {
            cancellableProgressSource.incrementCompletedUnitCount(by: 1)
            try? await Task.sleep(for: .milliseconds(100))
        }
    }

    view.linkNSyncTask = Task {
        await task.value
    }

    return view
}
#endif
