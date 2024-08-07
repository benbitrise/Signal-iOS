//
// Copyright 2020 Signal Messenger, LLC
// SPDX-License-Identifier: AGPL-3.0-only
//

import LibSignalClient
import SignalRingRTC
import SignalServiceKit
import SignalUI
import Combine

// MARK: - GroupCallMemberSheet

class GroupCallMemberSheet: InteractiveSheetViewController {

    // MARK: Properties

    override var interactiveScrollViews: [UIScrollView] { [tableView] }

    private let tableView = UITableView(frame: .zero, style: .insetGrouped)
    private let call: SignalCall
    private let ringRtcCall: SignalRingRTC.GroupCall
    private let groupThreadCall: GroupThreadCall

    override var sheetBackgroundColor: UIColor {
        self.tableView.backgroundColor ?? .systemGroupedBackground
    }

    init(call: SignalCall, groupThreadCall: GroupThreadCall) {
        self.call = call
        self.ringRtcCall = groupThreadCall.ringRtcCall
        self.groupThreadCall = groupThreadCall

        super.init(blurEffect: nil)

        self.overrideUserInterfaceStyle = .dark
        groupThreadCall.addObserver(self, syncStateImmediately: true)
    }

    // MARK: - Table setup

    private typealias DiffableDataSource = UITableViewDiffableDataSource<Section, RowID>
    private typealias Snapshot = NSDiffableDataSourceSnapshot<Section, RowID>

    private enum Section: Hashable {
        case raisedHands
        case inCall
    }

    private struct RowID: Hashable {
        var section: Section
        var memberID: JoinedMember.ID
    }

    private lazy var dataSource = DiffableDataSource(
        tableView: tableView
    ) { [weak self] tableView, indexPath, id -> UITableViewCell? in
        guard let cell = tableView.dequeueReusableCell(GroupCallMemberCell.self, for: indexPath) else { return nil }

        cell.ringRtcCall = self?.ringRtcCall

        guard let viewModel = self?.viewModelsByID[id.memberID] else {
            owsFailDebug("missing view model")
            return cell
        }

        cell.configure(with: viewModel, isHandRaised: id.section == .raisedHands)

        return cell
    }

    private class HeaderView: UIView {
        private let section: Section
        var memberCount: Int = 0 {
            didSet {
                self.updateText()
            }
        }

        private let label = UILabel()

        init(section: Section) {
            self.section = section
            super.init(frame: .zero)

            self.addSubview(self.label)
            self.label.autoPinEdgesToSuperviewMargins()
            self.updateText()
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) has not been implemented")
        }

        private func updateText() {
            let titleText: String = switch section {
            case .raisedHands:
                OWSLocalizedString(
                    "GROUP_CALL_MEMBER_LIST_RAISED_HANDS_SECTION_HEADER",
                    comment: "Title for the section of the group call member list which displays the list of members with their hand raised."
                )
            case .inCall:
                OWSLocalizedString(
                    "GROUP_CALL_MEMBER_LIST_IN_CALL_SECTION_HEADER",
                    comment: "Title for the section of the group call member list which displays the list of all members in the call."
                )
            }

            label.attributedText = .composed(of: [
                titleText.styled(with: .font(.dynamicTypeHeadline)),
                " ",
                String(
                    format: OWSLocalizedString(
                        "GROUP_CALL_MEMBER_LIST_SECTION_HEADER_MEMBER_COUNT",
                        comment: "A count of members in a given group call member list section, displayed after the header."
                    ),
                    self.memberCount
                )
            ]).styled(
                with: .font(.dynamicTypeBody),
                .color(Theme.darkThemePrimaryColor)
            )
        }
    }

    private let raisedHandsHeader = HeaderView(section: .raisedHands)
    private let inCallHeader = HeaderView(section: .inCall)

    override public func viewDidLoad() {
        super.viewDidLoad()

        tableView.delegate = self
        tableView.tableHeaderView = UIView(frame: CGRect(origin: .zero, size: CGSize(width: 0, height: CGFloat.leastNormalMagnitude)))
        contentView.addSubview(tableView)
        tableView.autoPinEdgesToSuperviewEdges()

        tableView.register(GroupCallMemberCell.self, forCellReuseIdentifier: GroupCallMemberCell.reuseIdentifier)

        tableView.dataSource = self.dataSource

        updateMembers()
    }

    // MARK: - Table contents

    fileprivate struct JoinedMember {
        enum ID: Hashable {
            case aci(Aci)
            case demuxID(DemuxId)
        }

        let id: ID

        let aci: Aci
        let displayName: String
        let comparableName: DisplayName.ComparableValue
        let demuxID: DemuxId?
        let isLocalUser: Bool
        let isAudioMuted: Bool?
        let isVideoMuted: Bool?
        let isPresenting: Bool?
    }

    private var viewModelsByID: [JoinedMember.ID: GroupCallMemberCell.ViewModel] = [:]
    private var sortedMembers = [JoinedMember]() {
        didSet {
            let oldMemberIDs = viewModelsByID.keys
            let newMemberIDs = sortedMembers.map(\.id)
            let viewModelsToRemove = Set(oldMemberIDs).subtracting(newMemberIDs)
            viewModelsToRemove.forEach { viewModelsByID.removeValue(forKey: $0) }

            viewModelsByID = sortedMembers.reduce(into: viewModelsByID) { partialResult, member in
                if let existingViewModel = partialResult[member.id] {
                    existingViewModel.update(using: member)
                } else {
                    partialResult[member.id] = .init(member: member)
                }
            }
        }
    }

    private func updateMembers() {
        let unsortedMembers: [JoinedMember] = databaseStorage.read { transaction -> [JoinedMember] in
            let tsAccountManager = DependenciesBridge.shared.tsAccountManager
            guard let localIdentifiers = tsAccountManager.localIdentifiers(tx: transaction.asV2Read) else {
                return []
            }

            var members = [JoinedMember]()
            let config: DisplayName.ComparableValue.Config = .current()
            if self.ringRtcCall.localDeviceState.joinState == .joined {
                members += self.ringRtcCall.remoteDeviceStates.values.map { member in
                    let resolvedName: String
                    let comparableName: DisplayName.ComparableValue
                    if member.aci == localIdentifiers.aci {
                        resolvedName = OWSLocalizedString(
                            "GROUP_CALL_YOU_ON_ANOTHER_DEVICE",
                            comment: "Text describing the local user in the group call members sheet when connected from another device."
                        )
                        comparableName = .nameValue(resolvedName)
                    } else {
                        let displayName = self.contactsManager.displayName(for: member.address, tx: transaction)
                        resolvedName = displayName.resolvedValue(config: config.displayNameConfig)
                        comparableName = displayName.comparableValue(config: config)
                    }

                    return JoinedMember(
                        id: .demuxID(member.demuxId),
                        aci: member.aci,
                        displayName: resolvedName,
                        comparableName: comparableName,
                        demuxID: member.demuxId,
                        isLocalUser: false,
                        isAudioMuted: member.audioMuted,
                        isVideoMuted: member.videoMuted,
                        isPresenting: member.presenting
                    )
                }

                let displayName = CommonStrings.you
                let comparableName: DisplayName.ComparableValue = .nameValue(displayName)
                let id: JoinedMember.ID
                let demuxId: UInt32?
                if let localDemuxId = groupThreadCall.ringRtcCall.localDeviceState.demuxId {
                    id = .demuxID(localDemuxId)
                    demuxId = localDemuxId
                } else {
                    id = .aci(localIdentifiers.aci)
                    demuxId = nil
                }
                members.append(JoinedMember(
                    id: id,
                    aci: localIdentifiers.aci,
                    displayName: displayName,
                    comparableName: comparableName,
                    demuxID: demuxId,
                    isLocalUser: true,
                    isAudioMuted: self.ringRtcCall.isOutgoingAudioMuted,
                    isVideoMuted: self.ringRtcCall.isOutgoingVideoMuted,
                    isPresenting: false
                ))
            } else {
                // If we're not yet in the call, `remoteDeviceStates` will not exist.
                // We can get the list of joined members still, provided we are connected.
                members += self.ringRtcCall.peekInfo?.joinedMembers.map { aciUuid in
                    let aci = Aci(fromUUID: aciUuid)
                    let address = SignalServiceAddress(aci)
                    let displayName = self.contactsManager.displayName(for: address, tx: transaction)
                    return JoinedMember(
                        id: .aci(aci),
                        aci: aci,
                        displayName: displayName.resolvedValue(config: config.displayNameConfig),
                        comparableName: displayName.comparableValue(config: config),
                        demuxID: nil,
                        isLocalUser: false,
                        isAudioMuted: nil,
                        isVideoMuted: nil,
                        isPresenting: nil
                    )
                } ?? []
            }

            return members
        }

        sortedMembers = unsortedMembers.sorted {
            let nameComparison = $0.comparableName.isLessThanOrNilIfEqual($1.comparableName)
            if let nameComparison {
                return nameComparison
            }
            if $0.aci != $1.aci {
                return $0.aci < $1.aci
            }
            return $0.demuxID ?? 0 < $1.demuxID ?? 0
        }

        self.updateSnapshotAndHeaders()
    }

    private func updateSnapshotAndHeaders() {
        var snapshot = Snapshot()

        if !groupThreadCall.raisedHands.isEmpty {
            snapshot.appendSections([.raisedHands])
            snapshot.appendItems(
                groupThreadCall.raisedHands.map {
                    RowID(section: .raisedHands, memberID: .demuxID($0))
                },
                toSection: .raisedHands
            )

            raisedHandsHeader.memberCount = groupThreadCall.raisedHands.count
        }

        snapshot.appendSections([.inCall])
        snapshot.appendItems(
            sortedMembers.map { RowID(section: .inCall, memberID: $0.id) },
            toSection: .inCall
        )

        inCallHeader.memberCount = sortedMembers.count

        dataSource.apply(snapshot, animatingDifferences: true)
    }

}

// MARK: UITableViewDelegate

extension GroupCallMemberSheet: UITableViewDelegate {
    func tableView(_ tableView: UITableView, viewForHeaderInSection section: Int) -> UIView? {
        if section == 0, !groupThreadCall.raisedHands.isEmpty {
            return raisedHandsHeader
        } else {
            return inCallHeader
        }
    }

    func tableView(_ tableView: UITableView, heightForHeaderInSection section: Int) -> CGFloat {
        return UITableView.automaticDimension
    }

    func tableView(_ tableView: UITableView, heightForFooterInSection section: Int) -> CGFloat {
        return .leastNormalMagnitude
    }
}

// MARK: CallObserver

extension GroupCallMemberSheet: GroupCallObserver {
    func groupCallLocalDeviceStateChanged(_ call: GroupCall) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallRemoteDeviceStatesChanged(_ call: GroupCall) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallPeekChanged(_ call: GroupCall) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallEnded(_ call: GroupCall, reason: GroupCallEndReason) {
        AssertIsOnMainThread()
        updateMembers()
    }

    func groupCallReceivedRaisedHands(_ call: GroupCall, raisedHands: [DemuxId]) {
        AssertIsOnMainThread()
        updateSnapshotAndHeaders()
    }
}

// MARK: - GroupCallMemberCell

private class GroupCallMemberCell: UITableViewCell, ReusableTableViewCell {

    // MARK: ViewModel

    class ViewModel {
        typealias Member = GroupCallMemberSheet.JoinedMember

        let aci: Aci
        let name: String
        let isLocalUser: Bool

        @Published var shouldShowAudioMutedIcon = false
        @Published var shouldShowVideoMutedIcon = false
        @Published var shouldShowPresentingIcon = false

        init(member: Member) {
            self.aci = member.aci
            self.name = member.displayName
            self.isLocalUser = member.isLocalUser
            self.update(using: member)
        }

        func update(using member: Member) {
            owsAssertDebug(aci == member.aci)
            self.shouldShowAudioMutedIcon = member.isAudioMuted ?? false
            self.shouldShowVideoMutedIcon = member.isVideoMuted == true && member.isPresenting != true
            self.shouldShowPresentingIcon = member.isPresenting ?? false
        }
    }

    // MARK: Properties

    static let reuseIdentifier = "GroupCallMemberCell"

    var ringRtcCall: SignalRingRTC.GroupCall?

    private let avatarView = ConversationAvatarView(
        sizeClass: .thirtySix,
        localUserDisplayMode: .asUser,
        badged: false
    )

    private let nameLabel = UILabel()

    private lazy var lowerHandButton = OWSButton(
        title: CallStrings.lowerHandButton,
        tintColor: .ows_white,
        dimsWhenHighlighted: true
    ) { [weak self] in
        self?.ringRtcCall?.raiseHand(raise: false)
    }

    private let leadingWrapper = UIView()
    private let videoMutedIndicator = UIImageView()
    private let presentingIndicator = UIImageView()

    private let audioMutedIndicator = UIImageView()
    private let raisedHandIndicator = UIImageView()

    private var subscriptions = Set<AnyCancellable>()

    override init(style: UITableViewCell.CellStyle, reuseIdentifier: String?) {
        super.init(style: style, reuseIdentifier: reuseIdentifier)

        selectionStyle = .none

        nameLabel.textColor = Theme.darkThemePrimaryColor
        nameLabel.font = .dynamicTypeBody

        lowerHandButton.titleLabel?.font = .dynamicTypeBody

        func setup(iconView: UIImageView, withImageNamed imageName: String, in wrapper: UIView) {
            iconView.setTemplateImageName(imageName, tintColor: Theme.darkThemeSecondaryTextAndIconColor)
            wrapper.addSubview(iconView)
            iconView.autoPinEdgesToSuperviewEdges()
        }

        let trailingWrapper = UIView()
        setup(iconView: audioMutedIndicator, withImageNamed: "mic-slash", in: trailingWrapper)
        setup(iconView: raisedHandIndicator, withImageNamed: Theme.iconName(.raiseHand), in: trailingWrapper)

        setup(iconView: videoMutedIndicator, withImageNamed: "video-slash", in: leadingWrapper)
        setup(iconView: presentingIndicator, withImageNamed: "share_screen", in: leadingWrapper)

        let stackView = UIStackView(arrangedSubviews: [
            avatarView,
            nameLabel,
            lowerHandButton,
            leadingWrapper,
            trailingWrapper
        ])
        stackView.axis = .horizontal
        stackView.alignment = .center
        contentView.addSubview(stackView)
        stackView.autoPinEdgesToSuperviewMargins()

        stackView.spacing = 16
        stackView.setCustomSpacing(12, after: avatarView)
        stackView.setCustomSpacing(8, after: nameLabel)
    }

    required init?(coder aDecoder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    // MARK: Configuration

    // isHandRaised isn't part of ViewModel because the same view model is used
    // for any given member in both the members and raised hand sections.
    func configure(with viewModel: ViewModel, isHandRaised: Bool) {
        self.subscriptions.removeAll()

        if isHandRaised {
            self.raisedHandIndicator.isHidden = false
            self.lowerHandButton.isHiddenInStackView = !viewModel.isLocalUser
            self.audioMutedIndicator.isHidden = true
            self.leadingWrapper.isHiddenInStackView = true
        } else {
            self.raisedHandIndicator.isHidden = true
            self.lowerHandButton.isHiddenInStackView = true
            self.leadingWrapper.isHiddenInStackView = false
            self.subscribe(to: viewModel.$shouldShowAudioMutedIcon, showing: self.audioMutedIndicator)
            self.subscribe(to: viewModel.$shouldShowVideoMutedIcon, showing: self.videoMutedIndicator)
            self.subscribe(to: viewModel.$shouldShowPresentingIcon, showing: self.presentingIndicator)
        }

        self.nameLabel.text = viewModel.name
        self.avatarView.updateWithSneakyTransactionIfNecessary { config in
            config.dataSource = .address(SignalServiceAddress(viewModel.aci))
        }
    }

    private func subscribe(to publisher: Published<Bool>.Publisher, showing view: UIView) {
        publisher
            .removeDuplicates()
            .sink { [weak view] shouldShow in
                view?.isHidden = !shouldShow
            }
            .store(in: &self.subscriptions)
    }

}
