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
        index.issue(with: id)
    }

}
