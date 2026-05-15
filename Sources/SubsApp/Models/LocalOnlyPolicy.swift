import Foundation

enum ProcessingLocation: Equatable {
    case onDevice
    case cloud
}

struct LocalOnlyBackendDeclaration: Equatable {
    let name: String
    let purpose: String
    let location: ProcessingLocation
    let allowsCloudFallback: Bool
}

enum LocalOnlyPolicy {
    static func validate(_ backend: LocalOnlyBackendDeclaration) throws {
        guard backend.location == .onDevice, backend.allowsCloudFallback == false else {
            throw LocalOnlyPolicyError.cloudProcessingForbidden(backend.name)
        }
    }
}

enum LocalOnlyPolicyError: LocalizedError, Equatable {
    case cloudProcessingForbidden(String)

    var errorDescription: String? {
        switch self {
        case .cloudProcessingForbidden(let backendName):
            "\(backendName) is not allowed because Subs must keep realtime translation fully on-device."
        }
    }
}
