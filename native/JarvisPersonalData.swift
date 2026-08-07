import Contacts
import EventKit
import Foundation

private func emit(_ value: Any, exitCode: Int32 = 0) -> Never {
    do {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data([0x0A]))
        Foundation.exit(exitCode)
    } catch {
        Foundation.exit(70)
    }
}

private func eventAuthorization(_ status: EKAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .fullAccess: return "full_access"
    case .writeOnly: return "write_only"
    @unknown default: return "unknown"
    }
}

private func contactAuthorization(_ status: CNAuthorizationStatus) -> String {
    switch status {
    case .notDetermined: return "not_determined"
    case .restricted: return "restricted"
    case .denied: return "denied"
    case .authorized: return "authorized"
    @unknown default: return "unknown"
    }
}

private func status() -> [String: Any] {
    return [
        "calendar": eventAuthorization(EKEventStore.authorizationStatus(for: .event)),
        "reminders": eventAuthorization(EKEventStore.authorizationStatus(for: .reminder)),
        "contacts": contactAuthorization(CNContactStore.authorizationStatus(for: .contacts)),
        "notes": "shortcut_or_apple_event",
        "mail": "draft_only_until_confirmation",
        "files": "user_selected_roots",
        "clipboard": "session_retention",
    ]
}

private func requestCalendarAccess(_ store: EKEventStore) async throws -> Bool {
    switch EKEventStore.authorizationStatus(for: .event) {
    case .fullAccess: return true
    case .notDetermined: return try await store.requestFullAccessToEvents()
    default: return false
    }
}

private func requestReminderAccess(_ store: EKEventStore) async throws -> Bool {
    switch EKEventStore.authorizationStatus(for: .reminder) {
    case .fullAccess: return true
    case .notDetermined: return try await store.requestFullAccessToReminders()
    default: return false
    }
}

private func agenda(days: Int) async {
    let store = EKEventStore()
    do {
        guard try await requestCalendarAccess(store) else {
            emit(["ok": false, "error": "calendar_access_denied"], exitCode: 77)
        }
        let start = Date()
        let end = Calendar.current.date(
            byAdding: .day,
            value: min(max(days, 1), 31),
            to: start
        )!
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        let iso = ISO8601DateFormatter()
        let events = store.events(matching: predicate).map { event in
            [
                "title": event.title ?? "",
                "start": iso.string(from: event.startDate),
                "end": iso.string(from: event.endDate),
                "all_day": event.isAllDay,
                "calendar": event.calendar.title,
                "location": event.location ?? "",
                "notes": event.notes ?? "",
                "url": event.url?.absoluteString ?? "",
            ] as [String: Any]
        }
        emit(["ok": true, "events": events])
    } catch {
        emit(["ok": false, "error": error.localizedDescription], exitCode: 70)
    }
}

private func reminders() async {
    let store = EKEventStore()
    do {
        guard try await requestReminderAccess(store) else {
            emit(["ok": false, "error": "reminders_access_denied"], exitCode: 77)
        }
        let predicate = store.predicateForIncompleteReminders(
            withDueDateStarting: nil,
            ending: Calendar.current.date(byAdding: .day, value: 31, to: Date()),
            calendars: nil
        )
        let values: [EKReminder] = await withCheckedContinuation { continuation in
            store.fetchReminders(matching: predicate) { items in
                continuation.resume(returning: items ?? [])
            }
        }
        let iso = ISO8601DateFormatter()
        let output = values.map { reminder in
            [
                "title": reminder.title ?? "",
                "calendar": reminder.calendar.title,
                "priority": reminder.priority,
                "due": reminder.dueDateComponents.flatMap {
                    Calendar.current.date(from: $0)
                }.map(iso.string(from:)) ?? "",
                "notes": reminder.notes ?? "",
            ] as [String: Any]
        }
        emit(["ok": true, "reminders": output])
    } catch {
        emit(["ok": false, "error": error.localizedDescription], exitCode: 70)
    }
}

private func contacts(query: String) async {
    let store = CNContactStore()
    do {
        let current = CNContactStore.authorizationStatus(for: .contacts)
        let authorized = current == .authorized
            ? true
            : current == .notDetermined
                ? try await store.requestAccess(for: .contacts)
                : false
        guard authorized else {
            emit(["ok": false, "error": "contacts_access_denied"], exitCode: 77)
        }
        let keys: [CNKeyDescriptor] = [
            CNContactIdentifierKey as CNKeyDescriptor,
            CNContactGivenNameKey as CNKeyDescriptor,
            CNContactFamilyNameKey as CNKeyDescriptor,
            CNContactNicknameKey as CNKeyDescriptor,
            CNContactEmailAddressesKey as CNKeyDescriptor,
            CNContactPhoneNumbersKey as CNKeyDescriptor,
        ]
        let request = CNContactFetchRequest(keysToFetch: keys)
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var output: [[String: Any]] = []
        try store.enumerateContacts(with: request) { contact, stop in
            let name = [contact.givenName, contact.familyName]
                .filter { !$0.isEmpty }
                .joined(separator: " ")
            let searchable = "\(name) \(contact.nickname)".lowercased()
            guard needle.isEmpty || searchable.contains(needle) else { return }
            output.append([
                "identifier": contact.identifier,
                "name": name,
                "nickname": contact.nickname,
                "emails": contact.emailAddresses.map { String($0.value) },
                "phones": contact.phoneNumbers.map { $0.value.stringValue },
            ])
            if output.count >= 25 { stop.pointee = true }
        }
        emit(["ok": true, "contacts": output])
    } catch {
        emit(["ok": false, "error": error.localizedDescription], exitCode: 70)
    }
}

private func jsonArgument(_ value: String) throws -> [String: Any] {
    guard let data = value.data(using: .utf8),
          let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw NSError(
            domain: "dev.pbbuilds.jarvis.personal-data",
            code: 64,
            userInfo: [NSLocalizedDescriptionKey: "Invalid JSON payload."]
        )
    }
    return object
}

private func createEvent(payload: String) async {
    let store = EKEventStore()
    do {
        guard try await requestCalendarAccess(store) else {
            emit(["ok": false, "error": "calendar_access_denied"], exitCode: 77)
        }
        let value = try jsonArgument(payload)
        let title = (value["title"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let iso = ISO8601DateFormatter()
        guard !title.isEmpty,
              let start = iso.date(from: value["start"] as? String ?? ""),
              let end = iso.date(from: value["end"] as? String ?? ""),
              end > start else {
            emit(["ok": false, "error": "invalid_event"], exitCode: 64)
        }
        let event = EKEvent(eventStore: store)
        event.title = String(title.prefix(300))
        event.startDate = start
        event.endDate = end
        event.notes = (value["notes"] as? String).map { String($0.prefix(10_000)) }
        event.location = (value["location"] as? String).map { String($0.prefix(500)) }
        event.calendar = store.defaultCalendarForNewEvents
        try store.save(event, span: .thisEvent, commit: true)
        emit(["ok": true, "identifier": event.eventIdentifier ?? "", "title": event.title ?? ""])
    } catch {
        emit(["ok": false, "error": error.localizedDescription], exitCode: 70)
    }
}

private func createReminder(payload: String) async {
    let store = EKEventStore()
    do {
        guard try await requestReminderAccess(store) else {
            emit(["ok": false, "error": "reminders_access_denied"], exitCode: 77)
        }
        let value = try jsonArgument(payload)
        let title = (value["title"] as? String ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else {
            emit(["ok": false, "error": "invalid_reminder"], exitCode: 64)
        }
        let reminder = EKReminder(eventStore: store)
        reminder.title = String(title.prefix(300))
        reminder.notes = (value["notes"] as? String).map { String($0.prefix(10_000)) }
        reminder.calendar = store.defaultCalendarForNewReminders()
        if let dueValue = value["due"] as? String, !dueValue.isEmpty,
           let due = ISO8601DateFormatter().date(from: dueValue) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute],
                from: due
            )
        }
        try store.save(reminder, commit: true)
        emit([
            "ok": true,
            "identifier": reminder.calendarItemIdentifier,
            "title": reminder.title ?? "",
        ])
    } catch {
        emit(["ok": false, "error": error.localizedDescription], exitCode: 70)
    }
}

@main
private struct JarvisPersonalData {
    static func main() async {
        let arguments = CommandLine.arguments
        let command = arguments.dropFirst().first ?? "status"
        switch command {
        case "status":
            emit(status())
        case "agenda":
            await agenda(days: Int(arguments.dropFirst(2).first ?? "1") ?? 1)
        case "reminders":
            await reminders()
        case "contacts":
            await contacts(query: arguments.dropFirst(2).joined(separator: " "))
        case "create-event":
            await createEvent(payload: arguments.dropFirst(2).joined(separator: " "))
        case "create-reminder":
            await createReminder(payload: arguments.dropFirst(2).joined(separator: " "))
        default:
            emit(["ok": false, "error": "unsupported_command"], exitCode: 64)
        }
    }
}
