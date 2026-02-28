import Foundation
import Darwin
import AppKit
import UserNotifications

struct AppleNotifier {
    func notify(kind: NotificationKind, message: String) throws {
        guard runningFromValidAppBundle() else {
            throw OverseerError.system(
                "native notifications require running from a bundled macOS app target with a valid bundle identifier"
            )
        }

        let center = UNUserNotificationCenter.current()

        let status = try authorizationStatus(center: center)
        switch status {
        case .authorized, .ephemeral, .provisional:
            break
        case .notDetermined:
            let granted = try requestAuthorization(center: center)
            if !granted {
                openNotificationSettingsIfPossible()
                throw OverseerError.system("notification authorization is not allowed; enable notifications for Overseer in System Settings")
            }
        case .denied:
            openNotificationSettingsIfPossible()
            throw OverseerError.system("notification authorization is denied; enable notifications for Overseer in System Settings")
        @unknown default:
            throw OverseerError.system("notification authorization is unavailable")
        }

        let content = UNMutableNotificationContent()
        content.title = title(for: kind)
        content.body = message
        if #available(macOS 12.0, *) {
            content.interruptionLevel = .timeSensitive
            content.relevanceScore = 1.0
        }
        if let attachment = notificationIconAttachment() {
            content.attachments = [attachment]
        }

        let request = UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        )

        try addNotification(center: center, request: request)
    }

    private func title(for kind: NotificationKind) -> String {
        switch kind {
        case .warning:
            return "Overseer Warning"
        case .kill:
            return "Overseer Kill"
        case .monitor:
            return "Overseer Monitor"
        }
    }

    private func authorizationStatus(center: UNUserNotificationCenter) throws -> UNAuthorizationStatus {
        let statusBox = AuthorizationStatusBox()
        let sem = DispatchSemaphore(value: 0)

        center.getNotificationSettings { settings in
            statusBox.set(settings.authorizationStatus)
            sem.signal()
        }
        sem.wait()

        guard let status = statusBox.get() else {
            throw OverseerError.system("failed to fetch notification authorization status")
        }
        return status
    }

    private func requestAuthorization(center: UNUserNotificationCenter) throws -> Bool {
        let resultBox = BoolBox()
        let errorBox = ErrorBox()
        let sem = DispatchSemaphore(value: 0)

        center.requestAuthorization(options: [.alert, .badge, .sound]) { granted, error in
            resultBox.set(granted)
            if let error {
                errorBox.set(error)
            }
            sem.signal()
        }
        sem.wait()

        if let error = errorBox.get() as NSError? {
            if error.domain == UNErrorDomain, error.code == UNError.Code.notificationsNotAllowed.rawValue {
                return false
            }
            throw OverseerError.system("failed requesting notification authorization: \(error.localizedDescription)")
        }

        return resultBox.get() ?? false
    }

    private func notificationIconAttachment() -> UNNotificationAttachment? {
        guard let iconURL = Bundle.main.url(forResource: "OverseerRunner", withExtension: "png") else {
            return nil
        }
        do {
            return try UNNotificationAttachment(identifier: "overseer.icon", url: iconURL)
        } catch {
            return nil
        }
    }

    private func openNotificationSettingsIfPossible() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private func addNotification(center: UNUserNotificationCenter, request: UNNotificationRequest) throws {
        let errorBox = ErrorBox()
        let sem = DispatchSemaphore(value: 0)

        center.add(request) { error in
            if let error {
                errorBox.set(error)
            }
            sem.signal()
        }
        sem.wait()

        if let error = errorBox.get() {
            throw OverseerError.system("failed to submit notification: \(error.localizedDescription)")
        }
    }
}

struct DarwinSignalSender {
    func send(pid: Int32, signal: KillSignal) throws {
        let rawSignal: Int32
        switch signal {
        case .term:
            rawSignal = SIGTERM
        case .kill:
            rawSignal = SIGKILL
        case .int:
            rawSignal = SIGINT
        }

        if Darwin.kill(pid_t(pid), rawSignal) != 0 {
            let message = String(cString: strerror(errno))
            throw OverseerError.system("failed to send \(signal.rawValue) to pid \(pid): \(message)")
        }
    }
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Bool?

    func set(_ value: Bool) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Bool? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Error?

    func set(_ value: Error) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> Error? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class AuthorizationStatusBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value: UNAuthorizationStatus?

    func set(_ value: UNAuthorizationStatus) {
        lock.lock()
        self.value = value
        lock.unlock()
    }

    func get() -> UNAuthorizationStatus? {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
