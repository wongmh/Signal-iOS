//
//  Copyright (c) 2020 Open Whisper Systems. All rights reserved.
//

import Foundation

enum CVCBottomViewType: Equatable {
    // For perf reasons, we don't use a bottom view until
    // the view is about to appear for the first time.
    case none
    case inputToolbar
    case memberRequestView
    case messageRequestView(messageRequestType: MessageRequestType)
    case search
    case selection
    case blockingGroupMigration
}

// MARK: -

public extension ConversationViewController {

    internal var bottomViewType: CVCBottomViewType {
        get { viewState.bottomViewType }
        set {
            // For perf reasons, we avoid adding any "bottom view"
            // to the view hierarchy until its necessary, e.g. when
            // the view is about to appear.
            owsAssertDebug(hasViewWillAppearOccurred)

            if viewState.bottomViewType != newValue {
                viewState.bottomViewType = newValue
                updateBottomBar()
            }
        }
    }

    @objc
    func ensureBottomViewType() {
        AssertIsOnMainThread()

        bottomViewType = { () -> CVCBottomViewType in
            // The ordering of this method determines
            // precendence of the bottom views.

            if !hasViewWillAppearOccurred {
                return .none
            } else if threadViewModel.hasPendingMessageRequest {
                let messageRequestType = Self.databaseStorage.read { transaction in
                    MessageRequestView.messageRequestType(forThread: self.threadViewModel.threadRecord,
                                                          transaction: transaction)
                }
                return .messageRequestView(messageRequestType: messageRequestType)
            } else if isLocalUserRequestingMember {
                return .memberRequestView
            } else if hasBlockingGroupMigration {
                return .blockingGroupMigration
            } else {
                switch uiMode {
                case .search:
                    return .search
                case .selection:
                    return .selection
                case .normal:
                    return .inputToolbar
                }
            }
        }()
    }

    private func updateBottomBar() {
        AssertIsOnMainThread()

        // Animate the dismissal of any existing request view.
        dismissRequestView()

        requestView?.removeFromSuperview()
        requestView = nil

        let bottomView: UIView?
        switch bottomViewType {
        case .none:
            bottomView = nil
        case .messageRequestView:
            let messageRequestView = MessageRequestView(threadViewModel: threadViewModel)
            messageRequestView.delegate = self
            requestView = messageRequestView
            bottomView = messageRequestView
        case .memberRequestView:
            let memberRequestView = MemberRequestView(threadViewModel: threadViewModel,
                                                      fromViewController: self)
            memberRequestView.delegate = self
            requestView = memberRequestView
            bottomView = memberRequestView
        case .search:
            bottomView = searchController.resultsBar
        case .selection:
            bottomView = selectionToolbar
        case .inputToolbar:
            bottomView = inputToolbar
        case .blockingGroupMigration:
            let migrationView = BlockingGroupMigrationView(threadViewModel: threadViewModel,
                                                           fromViewController: self)
            requestView = migrationView
            bottomView = migrationView
        }

        for subView in bottomBar.subviews {
            subView.removeFromSuperview()
        }

        if let newBottomView = bottomView {
            bottomBar.addSubview(newBottomView)

            // The request views expect to extend into the safe area.
            if requestView != nil {
                newBottomView.autoPinEdgesToSuperviewEdges()
            } else {
                newBottomView.autoPinEdgesToSuperviewMargins()
            }
        }

        updateInputAccessoryPlaceholderHeight()
        updateContentInsets(animated: viewHasEverAppeared)
        updateInputVisibility()
    }

    // This is expensive. We only need to do it if conversationStyle has changed.
    //
    // TODO: Once conversationStyle is immutable, compare the old and new
    //       conversationStyle values and exit early if it hasn't changed.
    @objc
    func updateInputToolbar() {
        AssertIsOnMainThread()

        let existingDraft = inputToolbar.messageBody()

        let inputToolbar = buildInputToolbar(conversationStyle: conversationStyle)
        inputToolbar.setMessageBody(existingDraft, animated: false)
        self.inputToolbar = inputToolbar

        // updateBottomBar() is expensive and we need to avoid it while
        // initially configuring the view. viewWillAppear() will call
        // updateBottomBar(). After viewWillAppear(), we need to call
        // updateBottomBar() to reflect changes in the theme.
        if hasViewWillAppearOccurred {
            updateBottomBar()
        }
    }

    @objc
    func updateBottomBarPosition() {
        AssertIsOnMainThread()

        if let interactivePopGestureRecognizer = navigationController?.interactivePopGestureRecognizer {
            // Don't update the bottom bar position if an interactive pop is in progress
            switch interactivePopGestureRecognizer.state {
            case .possible, .failed:
                break
            default:
                return
            }
        }

        bottomBarBottomConstraint?.constant = -inputAccessoryPlaceholder.keyboardOverlap

        // We always want to apply the new bottom bar position immediately,
        // as this only happens during animations (interactive or otherwise)
        bottomBar.superview?.layoutIfNeeded()
    }

    @objc
    func updateInputAccessoryPlaceholderHeight() {
        AssertIsOnMainThread()

        // If we're currently dismissing interactively, skip updating the
        // input accessory height. Changing it while dismissing can lead to
        // an infinite loop of keyboard frame changes as the listeners in
        // InputAcessoryViewPlaceholder will end up calling back here if
        // a dismissal is in progress.
        if isDismissingInteractively {
            return
        }

        // Apply any pending layout changes to ensure we're measuring the up-to-date height.
        bottomBar.superview?.layoutIfNeeded()

        inputAccessoryPlaceholder.desiredHeight = bottomBar.height
    }

    // MARK: - Message Request

    @objc
    func showMessageRequestDialogIfRequiredAsync() {
        AssertIsOnMainThread()

        DispatchQueue.main.async { [weak self] in
            self?.showMessageRequestDialogIfRequired()
        }
    }

    @objc
    func showMessageRequestDialogIfRequired() {
        AssertIsOnMainThread()

        ensureBottomViewType()
    }

    @objc
    func updateInputVisibility() {
        AssertIsOnMainThread()

        if viewState.isInPreviewPlatter {
            inputToolbar.isHidden = true
            dismissKeyBoard()
            return
        }

        if self.userLeftGroup {
            // user has requested they leave the group. further sends disallowed
            inputToolbar.isHidden = true
            dismissKeyBoard()
        } else {
            inputToolbar.isHidden = false
        }
    }

    @objc
    func updateInputToolbarLayout() {
        AssertIsOnMainThread()

        inputToolbar.updateLayout(withSafeAreaInsets: view.safeAreaInsets)
    }

    @objc
    func popKeyBoard() {
        AssertIsOnMainThread()

        inputToolbar.beginEditingMessage()
    }

    @objc
    func dismissKeyBoard() {
        AssertIsOnMainThread()

        inputToolbar.endEditingMessage()
        inputToolbar.clearDesiredKeyboard()
    }

    private func dismissRequestView() {
        AssertIsOnMainThread()

        guard let requestView = self.requestView else {
            return
        }

        // Slide the request view off the bottom of the screen.
        let bottomInset: CGFloat = view.safeAreaInsets.bottom

        let dismissingView = requestView
        self.requestView = nil

        // Add the view on top of the new bottom bar (if there is one),
        // and then slide it off screen to reveal the new input view.
        view.addSubview(dismissingView)
        dismissingView.autoPinWidthToSuperview()
        dismissingView.autoPinEdge(toSuperviewEdge: .bottom)

        var endFrame = dismissingView.bounds
        endFrame.origin.y -= endFrame.size.height + bottomInset

        UIView.animate(withDuration: 0.2, delay: 0, options: []) {
            dismissingView.bounds = endFrame
        } completion: { (_) in
            dismissingView.removeFromSuperview()
        }
    }

    private var isLocalUserRequestingMember: Bool {
        guard let groupThread = thread as? TSGroupThread else {
            return false
        }
        return groupThread.isLocalUserRequestingMember
    }

    @objc
    var userLeftGroup: Bool {
        guard let groupThread = thread as? TSGroupThread else {
            return false
        }
        return !groupThread.isLocalUserFullMember
    }

    private var hasBlockingGroupMigration: Bool {
        thread.isBlockedByMigration
    }
}
