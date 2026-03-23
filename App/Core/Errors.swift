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

    case .invalidArguments(let message),
      .invalidConfig(let message),
      .io(let message),
      .commandTimedOut(let message),
      .commandFailed(let message),
      .system(let message):
      return message
    }
  }
}
