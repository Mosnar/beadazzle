import Foundation

extension BeadStore {
    func loadDependenciesForSelection() {
        guard let issue = selectedIssue else {
            if dependencyIssueID != nil {
                _dependencyIssueID = nil
            }
            if !dependencies.isEmpty {
                _dependencies = []
            }
            return
        }
        let nextDependencies = index.dependenciesTouching(issueID: issue.id)
        if dependencyIssueID != issue.id {
            _dependencyIssueID = issue.id
        }
        if dependencies != nextDependencies {
            _dependencies = nextDependencies
        }
        rebuildActivityItemsForSelection()
    }

    func dependencies(for issueID: String) -> [BeadDependency] {
        if dependencyIssueID == issueID {
            return dependencies
        }
        return index.dependenciesTouching(issueID: issueID)
    }

    func syncCommentsForSelectionFromCache() {
        guard let issue = selectedIssue else {
            commentLoadTask?.cancel()
            commentLoadTask = nil
            if commentsIssueID != nil {
                _commentsIssueID = nil
            }
            if !comments.isEmpty {
                _comments = []
            }
            _isLoadingComments = false
            _commentRefreshIssueID = nil
            _commentLoadError = nil
            return
        }

        let nextComments = commentCache[issue.id] ?? []
        if commentsIssueID != issue.id {
            _commentsIssueID = issue.id
        }
        if comments != nextComments {
            _comments = nextComments
        }
        if commentRefreshIssueID != issue.id {
            _commentRefreshIssueID = nil
            _isLoadingComments = false
        }
        rebuildActivityItemsForSelection()
    }

    func comments(for issueID: String) -> [BeadComment] {
        if commentsIssueID == issueID {
            return comments
        }
        return commentCache[issueID] ?? []
    }

    internal func clearSelectionSideData() {
        selectionSideDataTask?.cancel()
        selectionSideDataTask = nil
        commentLoadTask?.cancel()
        commentLoadTask = nil
        if dependencyIssueID != nil {
            _dependencyIssueID = nil
        }
        if !dependencies.isEmpty {
            _dependencies = []
        }
        if commentsIssueID != nil {
            _commentsIssueID = nil
        }
        if !comments.isEmpty {
            _comments = []
        }
        _commentRefreshIssueID = nil
        _commentLoadError = nil
        _isLoadingComments = false
        clearActivitySelection()
    }

    func isLoadingComments(for issueID: String) -> Bool {
        isLoadingComments && commentRefreshIssueID == issueID
    }

    func loadCommentsForSelection(force: Bool = false) {
        syncCommentsForSelectionFromCache()
        guard let issue = selectedIssue, let projectURL else { return }
        if !force, commentCache[issue.id] != nil { return }

        commentLoadTask?.cancel()
        _commentRefreshIssueID = issue.id
        _commentLoadError = nil
        _isLoadingComments = true
        let commands = commands
        let issueID = issue.id
        commentLoadTask = Task { @MainActor [weak self] in
            do {
                let loadedComments = try await commands.loadComments(projectURL: projectURL, issueID: issueID)
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.selectedIssue?.id == issueID else {
                    return
                }
                self.commentCache[issueID] = loadedComments
                self._commentsIssueID = issueID
                self._comments = loadedComments
                self._commentRefreshIssueID = nil
                self._isLoadingComments = false
                self.commentLoadTask = nil
                self.rebuildActivityItemsForSelection()
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.selectedIssue?.id == issueID else {
                    return
                }
                self._commentLoadError = error.localizedDescription
                self._commentRefreshIssueID = nil
                self._isLoadingComments = false
                self.commentLoadTask = nil
            }
        }
    }

    func commentLoadError(for issueID: String) -> String? {
        commentsIssueID == issueID ? commentLoadError : nil
    }

    func issue(with id: String) -> BeadIssue? {
        guard let issue = index.issue(with: id) else { return nil }
        return applyingStateLabelOverrides(to: issue)
    }

    func activityItems(for issueID: String) -> [IssueActivityItem] {
        activityIssueID == issueID ? activityItems : []
    }

    func isLoadingActivity(for issueID: String) -> Bool {
        isLoadingActivity && activityRefreshIssueID == issueID
    }

    func activityLoadError(for issueID: String) -> String? {
        activityIssueID == issueID ? activityLoadError : nil
    }

    /// Installs an immediate creation/relationship/comment presentation for a new
    /// selection, then the background history read enriches it with logged events.
    internal func prepareActivityForSelection() {
        guard let issue = selectedIssue else {
            clearActivitySelection()
            return
        }

        if activityIssueID != issue.id {
            _ = detail.beginActivityLoad()
            _activityIssueID = issue.id
            activityLoadedIssueID = nil
            activityEvents = []
            _activityRefreshIssueID = nil
            _activityLoadError = nil
            _isLoadingActivity = false
        }
        rebuildActivityItemsForSelection()
    }

    func loadActivityForSelection(force: Bool = false) {
        prepareActivityForSelection()
        guard let issue = selectedIssue, let projectURL else { return }
        let isAlreadyLoading = isLoadingActivity && activityRefreshIssueID == issue.id
        if !force, activityLoadedIssueID == issue.id || isAlreadyLoading {
            return
        }

        let issueID = issue.id
        let generation = detail.beginActivityLoad()
        _activityRefreshIssueID = issueID
        _activityLoadError = nil
        _isLoadingActivity = true
        let repository = activityHistoryRepository
        let validIssueIDs = index.allIssueIDs
        let issueSetRevision = project.issueReferenceLookup.revision

        activityLoadTask = Task { @MainActor [weak self] in
            defer { self?.detail.finishActivityLoad(generation: generation) }
            do {
                let loadedEvents = try await repository.events(
                    projectURL: projectURL,
                    issueID: issueID,
                    validIssueIDs: validIssueIDs,
                    issueSetRevision: issueSetRevision
                )
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.selectedIssue?.id == issueID,
                      self.detail.ownsActivityLoad(issueID: issueID, generation: generation) else {
                    return
                }
                self.activityEvents = loadedEvents
                self.activityLoadedIssueID = issueID
                self._activityRefreshIssueID = nil
                self._activityLoadError = nil
                self._isLoadingActivity = false
                self.rebuildActivityItemsForSelection()
            } catch is CancellationError {
                guard let self,
                      self.detail.ownsActivityLoad(issueID: issueID, generation: generation) else {
                    return
                }
                self._activityRefreshIssueID = nil
                self._isLoadingActivity = false
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.projectURL == projectURL,
                      self.selectedIssue?.id == issueID,
                      self.detail.ownsActivityLoad(issueID: issueID, generation: generation) else {
                    return
                }
                self._activityRefreshIssueID = nil
                self._activityLoadError = error.localizedDescription
                self._isLoadingActivity = false
            }
        }
    }

    func refreshActivityForSelection() {
        loadCommentsForSelection(force: true)
        loadActivityForSelection(force: true)
        // Dependencies and current issue status come from the authoritative snapshot.
        // Refresh it quietly so this control genuinely refreshes every activity source.
        refresh(reason: .manual, showsLoadingIndicator: false)
    }

    internal func rebuildActivityItemsForSelection() {
        guard let issue = selectedIssue, activityIssueID == issue.id else { return }
        let nextItems = IssueActivityTimeline.items(
            issue: issue,
            events: activityEvents,
            comments: comments(for: issue.id),
            dependencies: dependencies(for: issue.id),
            semantics: index.semantics,
            resolveIssue: { [index] in index.issue(with: $0) }
        )
        if activityItems != nextItems {
            _activityItems = nextItems
        }
    }

    private func clearActivitySelection() {
        if activityIssueID != nil || activityLoadedIssueID != nil || !activityItems.isEmpty {
            _ = detail.beginActivityLoad()
        }
        _activityIssueID = nil
        activityLoadedIssueID = nil
        activityEvents = []
        _activityItems = []
        _activityRefreshIssueID = nil
        _activityLoadError = nil
        _isLoadingActivity = false
    }
}
