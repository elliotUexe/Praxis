import Foundation

/// One dated class slot. Deliberately keyed by an exact calendar date rather than a
/// weekday-of-week template: real class schedules at Grenoble INP rotate week to week
/// (the same weekday+time slot hosts different courses across different weeks), so a
/// fixed weekly template produces false collisions. Verified against a real semester of
/// ADE-synced calendar data before choosing this shape.
struct ScheduleSlot: Codable {
    let date: String              // "yyyy-MM-dd", local (Europe/Paris)
    let start: String             // "HH:mm", 24h, local
    let end: String                // "HH:mm", 24h, local
    let courseVaultPath: String   // vault-relative path, e.g. "01_IMT/2A/INP/Automatique"
}

private struct ScheduleCacheFile: Codable {
    let schemaVersion: Int
    let generatedAt: String
    let slots: [ScheduleSlot]
}

/// Reads the pre-generated schedule cache (`90_Meta/staging/schedule_cache.json`, written
/// by the `.claude/skills/generate-schedule-cache` skill from Google Calendar — never
/// queried live from the app). Resolves "what course is happening right now" without any
/// network access.
enum ScheduleCache {
    static func load() -> [ScheduleSlot] {
        guard let data = try? Data(contentsOf: VaultPaths.scheduleCacheURL),
              let file = try? JSONDecoder().decode(ScheduleCacheFile.self, from: data) else {
            return []
        }
        return file.slots
    }

    /// Returns the vault-relative course path for the slot containing `date`, if any.
    static func courseVaultPath(for date: Date = Date()) -> String? {
        let slots = load()
        guard !slots.isEmpty else { return nil }

        let calendar = Calendar.current
        let dateFormatter = DateFormatter()
        dateFormatter.locale = Locale(identifier: "en_US_POSIX")
        dateFormatter.timeZone = TimeZone.current
        dateFormatter.dateFormat = "yyyy-MM-dd"
        let dayString = dateFormatter.string(from: date)

        let minutesNow = calendar.component(.hour, from: date) * 60 + calendar.component(.minute, from: date)

        for slot in slots where slot.date == dayString {
            guard let startMinutes = minutes(from: slot.start),
                  let endMinutes = minutes(from: slot.end) else { continue }
            if minutesNow >= startMinutes && minutesNow < endMinutes {
                return slot.courseVaultPath
            }
        }
        return nil
    }

    private static func minutes(from hhmm: String) -> Int? {
        let parts = hhmm.split(separator: ":")
        guard parts.count == 2, let h = Int(parts[0]), let m = Int(parts[1]) else { return nil }
        return h * 60 + m
    }
}
