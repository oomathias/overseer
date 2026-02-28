import Foundation

enum OverseerError: Error, CustomStringConvertible {
    case handled
    case invalidArguments(String)
    case invalidConfig(String)
    case io(String)
    case commandTimedOut(String)
    case commandFailed(String)
    case system(String)

    var description: String {
        switch self {
        case .handled:
            return "handled"
        case let .invalidArguments(message):
            return message
        case let .invalidConfig(message):
            return message
        case let .io(message):
            return message
        case let .commandTimedOut(message):
            return message
        case let .commandFailed(message):
            return message
        case let .system(message):
            return message
        }
    }
}
