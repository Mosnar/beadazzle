import Foundation

extension BeadStore {
    internal static func boolValue(_ userDefaults: UserDefaults, key: String, defaultValue: Bool) -> Bool {
        guard userDefaults.object(forKey: key) != nil else { return defaultValue }
        return userDefaults.bool(forKey: key)
    }

    private static func migratedBoolValue(
        _ userDefaults: UserDefaults,
        key: String,
        legacyKey: String,
        defaultValue: Bool
    ) -> Bool {
        if userDefaults.object(forKey: key) != nil {
            return userDefaults.bool(forKey: key)
        }
        guard userDefaults.object(forKey: legacyKey) != nil else { return defaultValue }
        let value = userDefaults.bool(forKey: legacyKey)
        userDefaults.set(value, forKey: key)
        return value
    }

    internal static func normalizedStaleCutoffDays(_ days: Int) -> Int {
        min(max(days, 1), 3_650)
    }

    internal func persistBDCLIPath() {
        let path = bdCLIPath.trimmingCharacters(in: .whitespacesAndNewlines)
        if path.isEmpty {
            userDefaults.removeObject(forKey: BeadazzlePreferenceKeys.bdCLIPath)
        } else {
            userDefaults.set(path, forKey: BeadazzlePreferenceKeys.bdCLIPath)
        }
    }

    internal func persistStaleCutoffDays() {
        guard let projectURL else { return }
        userDefaults.set(staleCutoffDays, forKey: BeadazzlePreferenceKeys.staleCutoffDays(projectURL: projectURL))
    }

    internal func loadProjectPreferences(for url: URL) {
        isLoadingProjectPreferences = true
        defer { isLoadingProjectPreferences = false }
        loadProjectVisibility(for: url)
        loadProjectListDisplayOptions(for: url)
        loadStaleCutoffDaysPreference(for: url)
        loadReadyParentRollUpPreference(for: url)
        loadExternalRefreshPreference(for: url)
        loadSavedViews(for: url)
    }

    private func loadSavedViews(for url: URL) {
        let result = savedViewRepository.load(projectURL: url)
        _savedViewTree = result.tree
        _savedViewCounts = [:]
        _savedViewPersistenceState = result.persistenceState
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        if result.rebuildsCounts {
            scheduleSavedViewCountRebuild()
        }
    }

    internal func persistSavedViews() {
        guard savedViewPersistenceState.canMutate else {
            lastError = savedViewsPersistenceMessage ?? "Bookmarks are read-only because their saved data could not be interpreted."
            return
        }
        guard let projectURL else { return }
        savedViewRepository.save(savedViewTree, projectURL: projectURL)
    }

    internal func normalizedSavedView(_ view: BeadSavedView) -> BeadSavedView {
        BeadSavedViewRepository.normalized(view)
    }

    func resetSavedViews() {
        guard let projectURL else { return }
        let reconcilesCurrentIdentity = activeSavedViewID != nil || sourceSavedViewID != nil
        savedViewRepository.reset(projectURL: projectURL)
        _savedViewTree = BeadSavedViewTree()
        _savedViewCounts = [:]
        _savedViewPersistenceState = .ready
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        scheduleSavedViewCountRebuild()
        if reconcilesCurrentIdentity {
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }

    func acceptRecoveredSavedViews() {
        guard case .recovered = savedViewPersistenceState, let projectURL else { return }
        guard savedViewRepository.save(savedViewTree, projectURL: projectURL) else {
            lastError = "The recovered bookmarks could not be saved."
            return
        }
        _savedViewPersistenceState = .ready
    }

    private func loadProjectVisibility(for url: URL) {
        _hiddenTypeNames = Set(userDefaults.stringArray(forKey: BeadazzlePreferenceKeys.hiddenTypes(projectURL: url)) ?? [])
        _hiddenStatusNames = Set(userDefaults.stringArray(forKey: BeadazzlePreferenceKeys.hiddenStatuses(projectURL: url)) ?? [])
    }

    private func loadProjectListDisplayOptions(for url: URL) {
        showsOwnerInBeadList = Self.migratedBoolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsOwnerInBeadList(projectURL: url),
            legacyKey: BeadazzlePreferenceKeys.legacyShowsOwnerInBeadList,
            defaultValue: false
        )
        showsAssigneeInBeadList = Self.migratedBoolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsAssigneeInBeadList(projectURL: url),
            legacyKey: BeadazzlePreferenceKeys.legacyShowsAssigneeInBeadList,
            defaultValue: false
        )
        showsDueDateInBeadList = Self.migratedBoolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsDueDateInBeadList(projectURL: url),
            legacyKey: BeadazzlePreferenceKeys.legacyShowsDueDateInBeadList,
            defaultValue: false
        )
        showsCommentsInBeadList = Self.migratedBoolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.showsCommentsInBeadList(projectURL: url),
            legacyKey: BeadazzlePreferenceKeys.legacyShowsCommentsInBeadList,
            defaultValue: true
        )
    }

    private func loadStaleCutoffDaysPreference(for url: URL) {
        let key = BeadazzlePreferenceKeys.staleCutoffDays(projectURL: url)
        let storedValue = userDefaults.object(forKey: key) as? Int
        let migratedValue = userDefaults.object(forKey: BeadazzlePreferenceKeys.legacyStaleCutoffDays) as? Int
        let value = Self.normalizedStaleCutoffDays(
            storedValue ?? migratedValue ?? BeadProjectIndex.defaultStaleCutoffDays
        )
        if storedValue == nil, migratedValue != nil {
            userDefaults.set(value, forKey: key)
        }
        staleCutoffDays = value
    }

    private func loadReadyParentRollUpPreference(for url: URL) {
        hidesParentsWithOnlyBlockedChildrenInReady = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.hidesParentsWithOnlyBlockedChildrenInReady(projectURL: url),
            defaultValue: true
        )
    }

    private func loadExternalRefreshPreference(for url: URL) {
        automaticallyRefreshesExternalChanges = Self.boolValue(
            userDefaults,
            key: BeadazzlePreferenceKeys.automaticallyRefreshesExternalChanges(projectURL: url),
            defaultValue: true
        )
    }

    internal func persistProjectVisibility() {
        guard let projectURL else { return }
        userDefaults.set(hiddenTypeNames.sorted(), forKey: BeadazzlePreferenceKeys.hiddenTypes(projectURL: projectURL))
        userDefaults.set(hiddenStatusNames.sorted(), forKey: BeadazzlePreferenceKeys.hiddenStatuses(projectURL: projectURL))
    }

    internal func persistProjectListDisplayOptions() {
        guard let projectURL else { return }
        userDefaults.set(
            showsOwnerInBeadList,
            forKey: BeadazzlePreferenceKeys.showsOwnerInBeadList(projectURL: projectURL)
        )
        userDefaults.set(
            showsAssigneeInBeadList,
            forKey: BeadazzlePreferenceKeys.showsAssigneeInBeadList(projectURL: projectURL)
        )
        userDefaults.set(
            showsDueDateInBeadList,
            forKey: BeadazzlePreferenceKeys.showsDueDateInBeadList(projectURL: projectURL)
        )
        userDefaults.set(
            showsCommentsInBeadList,
            forKey: BeadazzlePreferenceKeys.showsCommentsInBeadList(projectURL: projectURL)
        )
    }

    internal func persistReadyParentRollUpPreference() {
        guard let projectURL else { return }
        userDefaults.set(
            hidesParentsWithOnlyBlockedChildrenInReady,
            forKey: BeadazzlePreferenceKeys.hidesParentsWithOnlyBlockedChildrenInReady(projectURL: projectURL)
        )
    }

    internal func persistExternalRefreshPreference() {
        guard let projectURL else { return }
        userDefaults.set(
            automaticallyRefreshesExternalChanges,
            forKey: BeadazzlePreferenceKeys.automaticallyRefreshesExternalChanges(projectURL: projectURL)
        )
    }

    func isTypeHidden(_ name: String) -> Bool {
        hiddenTypeNames.contains(name)
    }

    func isStatusHidden(_ name: String) -> Bool {
        hiddenStatusNames.contains(name)
    }

    func setType(_ name: String, isHidden: Bool) {
        if isHidden {
            _hiddenTypeNames.insert(name)
        } else {
            _hiddenTypeNames.remove(name)
        }
        projectVisibilityDidChange()
    }

    func setStatus(_ name: String, isHidden: Bool) {
        if isHidden {
            _hiddenStatusNames.insert(name)
        } else {
            _hiddenStatusNames.remove(name)
        }
        projectVisibilityDidChange()
    }

    private func projectVisibilityDidChange() {
        persistProjectVisibility()
        applyFilters()
    }

}
