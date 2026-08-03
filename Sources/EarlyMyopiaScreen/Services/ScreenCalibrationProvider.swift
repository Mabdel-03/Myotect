import Darwin
import DevicePpi
import UIKit

extension Notification.Name {
    /// Posted whenever a manual calibration is saved or cleared. Object is the new
    /// `ScreenCalibration` on save, `nil` on clear.
    static let screenCalibrationDidChange = Notification.Name("screenCalibrationDidChange")
}

/// The UserDefaults persistence record for an operator-measured calibration. Bound to the exact
/// screen signature and schema version it was measured under.
private struct ManualScreenCalibration: Codable {
    let pointsPerMillimeter: Double
    let nativeScale: Double
    let screenSignature: String
    let schemaVersion: Int
}

/// Outcome of a DevicePpi database lookup for the current device.
enum DevicePpiResolution: Equatable {
    case verified(Double)
    case unknown(suggestedPPI: Double)
}

/// The display identity a calibration is bound to. Injected as a closure so tests can simulate
/// hardware changes.
struct ScreenDescriptor: Equatable {
    let machineIdentifier: String
    let nativeBounds: CGRect
    let nativeScale: Double

    var signature: String {
        ScreenCalibrationProvider.screenSignature(
            machineIdentifier: machineIdentifier,
            nativeBounds: nativeBounds,
            nativeScale: CGFloat(nativeScale)
        )
    }
}

enum ScreenCalibrationStatus: Equatable {
    case validated(ScreenCalibration)
    case manualCalibrationRequired(screenSignature: String)
}

/// Supplies the validated screen calibration used for optotype sizing.
///
/// `MyopiaScreenCoordinator` takes this as an injected dependency (per Myotect DI style) rather
/// than reading a singleton, so flows are testable with fixed calibrations.
protocol ScreenCalibrationProviding: AnyObject {
    var currentCalibration: ScreenCalibration? { get }
    var status: ScreenCalibrationStatus { get }
    var suggestedPointsPerMillimeter: Double { get }
    var screenSignature: String { get }
    @discardableResult
    func saveManualCalibration(pointsPerMillimeter: Double) -> ScreenCalibration?
    func clearManualCalibration()
}

/// Production provider ported from the sibling Distance Measure Test app
/// (`Core/ScreenCalibrationProvider.swift`), made injectable instead of a singleton.
///
/// Devices with a verified DevicePpi entry are calibrated automatically
/// (`ppm = ppi / nativeScale / 25.4`). Unknown devices require an operator ruler measurement,
/// persisted in UserDefaults bound to the exact screen signature; a record whose signature,
/// scale, or schema version no longer matches is deleted on sight so it can never resurface.
final class ScreenCalibrationProvider: ScreenCalibrationProviding {
    private let defaults: UserDefaults
    private let notificationCenter: NotificationCenter
    private let ppiResolution: () -> DevicePpiResolution
    private let screenDescriptor: () -> ScreenDescriptor
    private let storageKey = "ManualScreenCalibration"

    init(
        defaults: UserDefaults = .standard,
        notificationCenter: NotificationCenter = .default,
        ppiResolution: @escaping () -> DevicePpiResolution = ScreenCalibrationProvider.resolveDevicePpi,
        screenDescriptor: @escaping () -> ScreenDescriptor = ScreenCalibrationProvider.mainScreenDescriptor
    ) {
        self.defaults = defaults
        self.notificationCenter = notificationCenter
        self.ppiResolution = ppiResolution
        self.screenDescriptor = screenDescriptor
    }

    var screenSignature: String {
        screenDescriptor().signature
    }

    var currentCalibration: ScreenCalibration? {
        let descriptor = screenDescriptor()
        switch ppiResolution() {
        case .verified(let ppi):
            return Self.automaticCalibration(
                ppi: ppi,
                nativeScale: descriptor.nativeScale,
                screenSignature: descriptor.signature
            )
        case .unknown:
            return storedManualCalibration(for: descriptor)
        }
    }

    var status: ScreenCalibrationStatus {
        if let calibration = currentCalibration {
            return .validated(calibration)
        }
        return .manualCalibrationRequired(screenSignature: screenSignature)
    }

    /// Seed value for the manual-calibration ruler: the verified conversion when available,
    /// else the DevicePpi best guess for this device class.
    var suggestedPointsPerMillimeter: Double {
        let ppi: Double
        switch ppiResolution() {
        case .verified(let knownPPI):
            ppi = knownPPI
        case .unknown(let bestGuessPPI):
            ppi = bestGuessPPI
        }
        let nativeScale = screenDescriptor().nativeScale
        guard ppi.isFinite, ppi > 0, nativeScale.isFinite, nativeScale > 0 else {
            return 1
        }
        return ppi / nativeScale / 25.4
    }

    static func automaticCalibration(
        ppi: Double,
        nativeScale: Double,
        screenSignature: String
    ) -> ScreenCalibration? {
        guard ppi.isFinite, ppi > 0, nativeScale.isFinite, nativeScale > 0 else {
            return nil
        }
        return ScreenCalibration(
            pointsPerMillimeter: ppi / nativeScale / 25.4,
            nativeScale: nativeScale,
            source: .deviceDatabase,
            screenSignature: screenSignature,
            schemaVersion: ScreenCalibration.schemaVersion
        )
    }

    @discardableResult
    func saveManualCalibration(pointsPerMillimeter: Double) -> ScreenCalibration? {
        guard pointsPerMillimeter.isFinite, pointsPerMillimeter > 0 else { return nil }
        let descriptor = screenDescriptor()
        let nativeScale = descriptor.nativeScale
        guard nativeScale.isFinite, nativeScale > 0 else { return nil }
        let record = ManualScreenCalibration(
            pointsPerMillimeter: pointsPerMillimeter,
            nativeScale: nativeScale,
            screenSignature: descriptor.signature,
            schemaVersion: ScreenCalibration.schemaVersion
        )
        guard let data = try? JSONEncoder().encode(record) else { return nil }
        defaults.set(data, forKey: storageKey)
        let calibration = ScreenCalibration(
            pointsPerMillimeter: pointsPerMillimeter,
            nativeScale: nativeScale,
            source: .manual,
            screenSignature: descriptor.signature,
            schemaVersion: ScreenCalibration.schemaVersion
        )
        notificationCenter.post(name: .screenCalibrationDidChange, object: calibration)
        return calibration
    }

    func clearManualCalibration() {
        defaults.removeObject(forKey: storageKey)
        notificationCenter.post(name: .screenCalibrationDidChange, object: nil)
    }

    private func storedManualCalibration(for descriptor: ScreenDescriptor) -> ScreenCalibration? {
        guard let data = defaults.data(forKey: storageKey) else {
            return nil
        }
        guard let record = try? JSONDecoder().decode(ManualScreenCalibration.self, from: data) else {
            defaults.removeObject(forKey: storageKey)
            return nil
        }
        let calibration = Self.manualCalibration(
            pointsPerMillimeter: record.pointsPerMillimeter,
            nativeScale: record.nativeScale,
            storedScreenSignature: record.screenSignature,
            storedSchemaVersion: record.schemaVersion,
            currentScreenSignature: descriptor.signature,
            currentNativeScale: descriptor.nativeScale
        )
        if calibration == nil {
            // A calibration is valid for one exact hardware/display signature.
            // Once that signature changes, do not let the stale record resurface.
            defaults.removeObject(forKey: storageKey)
        }
        return calibration
    }

    static func manualCalibration(
        pointsPerMillimeter: Double,
        nativeScale: Double,
        storedScreenSignature: String,
        storedSchemaVersion: Int,
        currentScreenSignature: String,
        currentNativeScale: Double
    ) -> ScreenCalibration? {
        guard pointsPerMillimeter.isFinite,
              pointsPerMillimeter > 0,
              nativeScale.isFinite,
              nativeScale > 0,
              currentNativeScale.isFinite,
              currentNativeScale > 0,
              storedSchemaVersion == ScreenCalibration.schemaVersion,
              storedScreenSignature == currentScreenSignature,
              nativeScale == currentNativeScale else {
            return nil
        }
        return ScreenCalibration(
            pointsPerMillimeter: pointsPerMillimeter,
            nativeScale: nativeScale,
            source: .manual,
            screenSignature: storedScreenSignature,
            schemaVersion: storedSchemaVersion
        )
    }

    static func screenSignature(
        machineIdentifier: String,
        nativeBounds: CGRect,
        nativeScale: CGFloat
    ) -> String {
        let width = Int(nativeBounds.width.rounded())
        let height = Int(nativeBounds.height.rounded())
        return "\(machineIdentifier)|\(width)x\(height)|\(SizingMetadataFormat.decimal(Double(nativeScale), places: 4))"
    }

    private static var machineIdentifier: String {
        if let simulatorIdentifier = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] {
            return simulatorIdentifier
        }
        var systemInfo = utsname()
        uname(&systemInfo)
        return withUnsafePointer(to: &systemInfo.machine) {
            $0.withMemoryRebound(to: CChar.self, capacity: 1) {
                String(cString: $0)
            }
        }
    }

    private static func resolveDevicePpi() -> DevicePpiResolution {
        switch Ppi.get() {
        case .success(let ppi):
            return .verified(ppi)
        case .unknown(let bestGuessPPI, _):
            return .unknown(suggestedPPI: bestGuessPPI)
        }
    }

    private static func mainScreenDescriptor() -> ScreenDescriptor {
        ScreenDescriptor(
            machineIdentifier: machineIdentifier,
            nativeBounds: UIScreen.main.nativeBounds,
            nativeScale: Double(UIScreen.main.nativeScale)
        )
    }
}

/// Fixed-state provider for tests and previews: either starts validated with the given
/// calibration, or starts uncalibrated so manual-calibration flows can be exercised without
/// touching UserDefaults.
final class StaticScreenCalibrationProvider: ScreenCalibrationProviding {
    let screenSignature: String
    var suggestedPointsPerMillimeter: Double
    private let nativeScale: Double
    private(set) var currentCalibration: ScreenCalibration?

    init(calibration: ScreenCalibration) {
        screenSignature = calibration.screenSignature
        suggestedPointsPerMillimeter = calibration.pointsPerMillimeter
        nativeScale = calibration.nativeScale
        currentCalibration = calibration
    }

    init(
        uncalibratedSignature: String,
        suggestedPointsPerMillimeter: Double = 6.0,
        nativeScale: Double = 3.0
    ) {
        screenSignature = uncalibratedSignature
        self.suggestedPointsPerMillimeter = suggestedPointsPerMillimeter
        self.nativeScale = nativeScale
        currentCalibration = nil
    }

    var status: ScreenCalibrationStatus {
        if let currentCalibration {
            return .validated(currentCalibration)
        }
        return .manualCalibrationRequired(screenSignature: screenSignature)
    }

    @discardableResult
    func saveManualCalibration(pointsPerMillimeter: Double) -> ScreenCalibration? {
        guard pointsPerMillimeter.isFinite, pointsPerMillimeter > 0 else { return nil }
        let calibration = ScreenCalibration(
            pointsPerMillimeter: pointsPerMillimeter,
            nativeScale: nativeScale,
            source: .manual,
            screenSignature: screenSignature,
            schemaVersion: ScreenCalibration.schemaVersion
        )
        currentCalibration = calibration
        return calibration
    }

    func clearManualCalibration() {
        currentCalibration = nil
    }
}
