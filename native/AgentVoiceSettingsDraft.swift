import Foundation

struct AgentVoiceSettingsDraft: Codable, Equatable, Sendable {
    enum Field: String, Codable, CaseIterable, Sendable { case endpoint, model, voiceID, wakePhrase }

    struct Form: Codable, Equatable, Sendable {
        var endpoint: String, model: String, voiceID: String, wakePhrase: String
        var voiceEnabled: Bool, wakeEnabled: Bool
        var pauseSeconds: Double
        static let pauses = [2.0, 3.0, 5.0]

        subscript(_ field: Field) -> String {
            switch field {
            case .endpoint: return endpoint
            case .model: return model
            case .voiceID: return voiceID
            case .wakePhrase: return wakePhrase
            }
        }

        var valuesWithoutWake: [String] { Field.allCases.map { self[$0] } + [String(voiceEnabled), String(pauseSeconds)] }
        var valid: Bool {
            let address = endpoint.trimmingCharacters(in: .whitespacesAndNewlines)
            let partialAddresses = ["", "https:", "https:/", "https://", "http:", "http:/", "http://"]
            return Field.allCases.allSatisfy { self[$0].utf8.count <= 4096 && !self[$0].contains("\0") } &&
                (partialAddresses.contains(address) || (try? CompanionService.endpoint(address)) != nil) &&
                Self.pauses.contains(pauseSeconds)
        }
    }

    let base: String
    let form: Form
    let focus: Field?
    let selection: AgentTextViewport.Selection?

    var valid: Bool {
        AgentSettingsRecovery.validHash(base) && form.valid &&
            (selection == nil || focus.flatMap { selection?.valid(in: form[$0].utf16.count) } == true)
    }

    static func fingerprint(_ preferences: PetPreferences) -> String? {
        let form = Form(endpoint: preferences.voiceEndpoint, model: preferences.voiceModel,
            voiceID: preferences.voiceID, wakePhrase: preferences.wakePhrase, voiceEnabled: preferences.voiceEnabled,
            wakeEnabled: preferences.wakeEnabled, pauseSeconds: preferences.voicePauseSeconds)
        let encoder = JSONEncoder(); encoder.outputFormatting = .sortedKeys
        return (try? encoder.encode(form)).map(AgentFiles.hash)
    }

    static func validateObject(_ raw: Any) throws {
        let draft = try AgentSettingsRecovery.object(raw, keys: ["base", "form", "focus", "selection"])
        _ = try AgentSettingsRecovery.object(draft["form"] ?? NSNull(), keys: ["endpoint", "model", "voiceID", "wakePhrase", "voiceEnabled", "wakeEnabled", "pauseSeconds"])
        if let selection = draft["selection"], !(selection is NSNull) {
            _ = try AgentSettingsRecovery.object(selection, keys: ["location", "length"])
        }
    }
}
