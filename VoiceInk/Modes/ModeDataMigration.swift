import Foundation

extension ModeManager {
    func migratedModeConfigurationData(for configKey: String) -> Data? {
        let defaults = UserDefaults.standard
        if let data = defaults.data(forKey: configKey) {
            return data
        }

        guard let legacyData = defaults.data(forKey: LegacyModeDataKey.configurations) else {
            return nil
        }

        defaults.set(legacyData, forKey: configKey)
        return legacyData
    }

    func migrateLoadedModeConfigurationsIfNeeded() {
        var didChange = false

        for index in configurations.indices {
            var config = configurations[index]
            var changedConfig = false

            if config.selectedTranscriptionModelName == nil {
                config.selectedTranscriptionModelName = UserDefaults.standard.string(
                    forKey: "CurrentTranscriptionModel")
                changedConfig = true
            }

            if config.selectedLanguage == nil {
                config.selectedLanguage = UserDefaults.standard.string(forKey: "SelectedLanguage") ?? "en"
                changedConfig = true
            }

            if config.selectedAIProvider == nil {
                config.selectedAIProvider = UserDefaults.standard.string(forKey: "selectedAIProvider")
                changedConfig = true
            }

            // Must run after the fill above, which can copy the legacy provider
            // string out of UserDefaults when ModeManager loads before AIService
            // has migrated it. Leaving it would make AIProvider(rawValue:) return
            // nil and silently disable enhancement for this Mode.
            if config.selectedAIProvider == AIService.legacyLocalProviderRawValue {
                config.selectedAIProvider = AIProvider.voiceInkRefine.rawValue
                changedConfig = true
            }

            if config.selectedAIModel == nil,
                let provider = config.selectedAIProvider
            {
                var storedModel = UserDefaults.standard.string(forKey: "\(provider)SelectedModel")
                if storedModel == nil, provider == AIProvider.voiceInkRefine.rawValue {
                    // Same ordering hazard: the new per-provider key may not have
                    // been written yet this launch.
                    storedModel = UserDefaults.standard.string(
                        forKey: "\(AIService.legacyLocalProviderRawValue)SelectedModel")
                }
                config.selectedAIModel = storedModel
                changedConfig = true
            }

            if config.isAIEnhancementEnabled && config.selectedPrompt == nil {
                config.selectedPrompt = UserDefaults.standard.string(forKey: "selectedPromptId")
                changedConfig = true
            }

            if changedConfig {
                configurations[index] = config
                didChange = true
            }
        }

        if didChange {
            saveConfigurations()
        }

        migrateLegacyShortcutStorageIfNeeded()
    }
    private func migrateLegacyShortcutStorageIfNeeded() {
        let defaults = UserDefaults.standard

        for config in configurations {
            let oldShortcutKey = "\(LegacyModeDataKey.shortcutPrefix)\(config.id.uuidString)"
            let newShortcutKey = ShortcutAction.mode(config.id).userDefaultsKey

            if defaults.object(forKey: newShortcutKey) == nil,
                let oldShortcutData = defaults.data(forKey: oldShortcutKey)
            {
                defaults.set(oldShortcutData, forKey: newShortcutKey)
            }

            let oldClearedKey = "\(oldShortcutKey)_cleared"
            let newClearedKey = "\(newShortcutKey)_cleared"
            if defaults.object(forKey: newClearedKey) == nil,
                defaults.object(forKey: oldClearedKey) != nil
            {
                defaults.set(defaults.bool(forKey: oldClearedKey), forKey: newClearedKey)
            }
        }
    }
}

private enum LegacyModeDataKey {
    static let configurations = "powerModeConfigurationsV2"
    static let shortcutPrefix = "Shortcut_powerMode_"
}
