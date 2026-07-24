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
        loadPinnedStateDimensions(for: url)
        loadStateDimensionDisplayNames(for: url)
        loadStateValueDisplayNames(for: url)
        loadArchivedStateValues(for: url)
        loadSavedViews(for: url)
    }

    private func loadPinnedStateDimensions(for url: URL) {
        let stored = userDefaults.stringArray(forKey: BeadazzlePreferenceKeys.pinnedStateDimensions(projectURL: url)) ?? []
        pinnedStateDimensions = Self.normalizedPinnedStateDimensions(stored)
    }

    internal func persistPinnedStateDimensions() {
        guard let projectURL else { return }
        userDefaults.set(
            pinnedStateDimensions,
            forKey: BeadazzlePreferenceKeys.pinnedStateDimensions(projectURL: projectURL)
        )
    }

    private func loadStateDimensionDisplayNames(for url: URL) {
        let key = BeadazzlePreferenceKeys.stateDimensionDisplayNames(projectURL: url)
        let stored = userDefaults.dictionary(forKey: key)?.compactMapValues { $0 as? String } ?? [:]
        stateDimensionDisplayNames = Self.normalizedStateDimensionDisplayNames(stored)
    }

    internal func persistStateDimensionDisplayNames() {
        guard let projectURL else { return }
        let key = BeadazzlePreferenceKeys.stateDimensionDisplayNames(projectURL: projectURL)
        if stateDimensionDisplayNames.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(stateDimensionDisplayNames, forKey: key)
        }
    }

    private func loadStateValueDisplayNames(for url: URL) {
        let key = BeadazzlePreferenceKeys.stateValueDisplayNames(projectURL: url)
        let rawNames = userDefaults.dictionary(forKey: key) ?? [:]
        let storedNames = rawNames.reduce(into: [String: [String: String]]()) { result, entry in
            guard let names = entry.value as? [String: String] else { return }
            result[entry.key] = names
        }
        stateValueDisplayNames = Self.normalizedStateValueDisplayNames(storedNames)
    }

    internal func persistStateValueDisplayNames() {
        guard let projectURL else { return }
        let key = BeadazzlePreferenceKeys.stateValueDisplayNames(projectURL: projectURL)
        if stateValueDisplayNames.isEmpty {
            userDefaults.removeObject(forKey: key)
        } else {
            userDefaults.set(stateValueDisplayNames, forKey: key)
        }
    }

    private func loadArchivedStateValues(for url: URL) {
        let key = BeadazzlePreferenceKeys.archivedStateValues(projectURL: url)
        let rawValues = userDefaults.dictionary(forKey: key) ?? [:]
        let storedValues = rawValues.reduce(into: [String: Set<String>]()) { result, entry in
            guard let values = entry.value as? [String] else { return }
            result[entry.key] = Set(values)
        }
        archivedStateValuesByDimension = Self.normalizedArchivedStateValues(storedValues)
    }

    internal func persistArchivedStateValues() {
        guard let projectURL else { return }
        let key = BeadazzlePreferenceKeys.archivedStateValues(projectURL: projectURL)
        if archivedStateValuesByDimension.isEmpty {
            userDefaults.removeObject(forKey: key)
            return
        }
        let storedValues = archivedStateValuesByDimension.mapValues { values in
            values.sorted(by: BeadStateLabel.isOrderedBefore)
        }
        userDefaults.set(storedValues, forKey: key)
    }

    /// Drops entries that are not valid dimension names and de-duplicates while
    /// preserving the user's pin order.
    internal static func normalizedPinnedStateDimensions(_ dimensions: [String]) -> [String] {
        var seen: Set<String> = []
        return dimensions.compactMap { raw in
            guard let dimension = BeadStateLabel.normalizedDimensionInput(raw),
                  seen.insert(dimension).inserted else {
                return nil
            }
            return dimension
        }
    }

    /// Sanitizes persisted presentation names and omits names that match the
    /// derived default so preferences only store meaningful overrides.
    internal static func normalizedStateDimensionDisplayNames(
        _ displayNames: [String: String]
    ) -> [String: String] {
        var normalizedNames: [String: String] = [:]
        for rawDimension in displayNames.keys.sorted() {
            guard let dimension = BeadStateLabel.normalizedDimensionInput(rawDimension),
                  let rawDisplayName = displayNames[rawDimension] else { continue }
            let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !displayName.isEmpty,
                  !displayName.contains(where: \Character.isNewline),
                  displayName != BeadStateLabel.displayName(for: dimension) else { continue }
            normalizedNames[dimension] = displayName
        }
        return normalizedNames
    }

    /// Sanitizes sparse value-name overrides. Raw values remain exact because
    /// they are part of the persisted `dimension:value` label contract.
    internal static func normalizedStateValueDisplayNames(
        _ displayNames: [String: [String: String]]
    ) -> [String: [String: String]] {
        var normalizedNames: [String: [String: String]] = [:]
        for rawDimension in displayNames.keys.sorted() {
            guard BeadStateLabel.normalizedDimensionInput(rawDimension) == rawDimension,
                  let rawNames = displayNames[rawDimension] else { continue }
            var dimensionNames: [String: String] = [:]
            for rawValue in rawNames.keys.sorted() {
                guard BeadStateLabel.normalizedValueInput(rawValue) == rawValue,
                      let rawDisplayName = rawNames[rawValue] else { continue }
                let displayName = rawDisplayName.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !displayName.isEmpty,
                      !displayName.contains(where: \Character.isNewline),
                      displayName != rawValue else { continue }
                dimensionNames[rawValue] = displayName
            }
            if !dimensionNames.isEmpty {
                normalizedNames[rawDimension] = dimensionNames
            }
        }
        return normalizedNames
    }

    internal static func normalizedArchivedStateValues(
        _ archivedValues: [String: Set<String>]
    ) -> [String: Set<String>] {
        var normalizedValues: [String: Set<String>] = [:]
        for rawDimension in archivedValues.keys.sorted() {
            guard BeadStateLabel.normalizedDimensionInput(rawDimension) == rawDimension,
                  let rawValues = archivedValues[rawDimension] else { continue }
            let values = Set(rawValues.filter {
                BeadStateLabel.normalizedValueInput($0) == $0
            })
            if !values.isEmpty {
                normalizedValues[rawDimension] = values
            }
        }
        return normalizedValues
    }

    private func loadSavedViews(for url: URL) {
        let result = savedViewRepository.load(projectURL: url)
        _savedViews = result.views
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
        savedViewRepository.save(savedViews, projectURL: projectURL)
    }

    internal func normalizedSavedView(_ view: BeadSavedView) -> BeadSavedView {
        BeadSavedViewRepository.normalized(view)
    }

    func resetSavedViews() {
        guard let projectURL else { return }
        let wasShowingFolder = isShowingFolder
        let reconcilesCurrentIdentity = activeSavedViewID != nil || sourceSavedViewID != nil
        savedViewRepository.reset(projectURL: projectURL)
        _savedViews = []
        _savedViewCounts = [:]
        _savedViewPersistenceState = .ready
        _activeSavedViewID = nil
        _sourceSavedViewID = nil
        if wasShowingFolder {
            _listOrdering = .sorted(BeadSavedViewSort(field: sort, direction: sortDirection))
        }
        scheduleSavedViewCountRebuild()
        if wasShowingFolder {
            applyFilters()
        }
        if reconcilesCurrentIdentity {
            syncCurrentWorkspaceSnapshotIfNeeded()
        }
    }

    func acceptRecoveredSavedViews() {
        guard case .recovered = savedViewPersistenceState, let projectURL else { return }
        guard savedViewRepository.save(savedViews, projectURL: projectURL) else {
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
