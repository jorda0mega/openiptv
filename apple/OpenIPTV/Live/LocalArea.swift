import CoreLocation
import Foundation

/// Where local channels come from: providers carry every US market's ABC,
/// NBC, CBS, FOX, CW and PBS, named with the state ("TX: ABC 8 Dallas").
struct LocalArea: Codable, Hashable {
    /// Two-letter state code, "TX".
    var state: String
    /// "Dallas", when known; its channels come first.
    var city: String?

    var label: String {
        [city, Self.states[state]].compactMap { $0?.isEmpty == false ? $0 : nil }.joined(separator: ", ")
    }

    /// Whether a channel's name says it's from this area ("TX: …",
    /// "TX | …", "TX - …").
    func includes(_ channelName: String) -> Bool {
        let name = channelName.trimmingCharacters(in: .whitespaces).uppercased()
        guard name.hasPrefix(state) else { return false }
        let rest = name.dropFirst(state.count).trimmingCharacters(in: .whitespaces)
        return rest.hasPrefix(":") || rest.hasPrefix("|") || rest.hasPrefix("-")
    }

    static let states: [String: String] = [
        "AL": "Alabama", "AK": "Alaska", "AZ": "Arizona", "AR": "Arkansas", "CA": "California", "CO": "Colorado",
        "CT": "Connecticut", "DE": "Delaware", "DC": "District of Columbia", "FL": "Florida", "GA": "Georgia",
        "HI": "Hawaii", "ID": "Idaho", "IL": "Illinois", "IN": "Indiana", "IA": "Iowa", "KS": "Kansas",
        "KY": "Kentucky", "LA": "Louisiana", "ME": "Maine", "MD": "Maryland", "MA": "Massachusetts",
        "MI": "Michigan", "MN": "Minnesota", "MS": "Mississippi", "MO": "Missouri", "MT": "Montana",
        "NE": "Nebraska", "NV": "Nevada", "NH": "New Hampshire", "NJ": "New Jersey", "NM": "New Mexico",
        "NY": "New York", "NC": "North Carolina", "ND": "North Dakota", "OH": "Ohio", "OK": "Oklahoma",
        "OR": "Oregon", "PA": "Pennsylvania", "PR": "Puerto Rico", "RI": "Rhode Island", "SC": "South Carolina",
        "SD": "South Dakota", "TN": "Tennessee", "TX": "Texas", "UT": "Utah", "VT": "Vermont", "VA": "Virginia",
        "WA": "Washington", "WV": "West Virginia", "WI": "Wisconsin", "WY": "Wyoming",
    ]

    static func code(for state: String) -> String? {
        let upper = state.uppercased()
        if states[upper] != nil { return upper }
        return states.first { $0.value.caseInsensitiveCompare(state) == .orderedSame }?.key
    }
}

#if os(iOS)
/// "Use my location": an approximate location once, turned into a state
/// and city on the device. Nothing is sent anywhere or kept but the area.
@MainActor
final class AreaLocator: NSObject, CLLocationManagerDelegate {
    private let manager = CLLocationManager()
    private var waiting: CheckedContinuation<CLLocation?, Never>?

    func locate() async -> LocalArea? {
        manager.delegate = self
        manager.desiredAccuracy = kCLLocationAccuracyReduced
        let location = await withCheckedContinuation { (done: CheckedContinuation<CLLocation?, Never>) in
            waiting = done
            switch manager.authorizationStatus {
            case .notDetermined: manager.requestWhenInUseAuthorization()
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            default: finish(nil)
            }
        }
        guard let location else { return nil }
        let place = try? await CLGeocoder().reverseGeocodeLocation(location).first
        guard place?.isoCountryCode == "US", let state = place?.administrativeArea.flatMap(LocalArea.code(for:)) else { return nil }
        return LocalArea(state: state, city: place?.locality)
    }

    private func finish(_ location: CLLocation?) {
        waiting?.resume(returning: location)
        waiting = nil
    }

    nonisolated func locationManagerDidChangeAuthorization(_ manager: CLLocationManager) {
        Task { @MainActor in
            switch manager.authorizationStatus {
            case .authorizedWhenInUse, .authorizedAlways: manager.requestLocation()
            case .denied, .restricted: finish(nil)
            default: break
            }
        }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didUpdateLocations locations: [CLLocation]) {
        let location = locations.last
        Task { @MainActor in finish(location) }
    }

    nonisolated func locationManager(_ manager: CLLocationManager, didFailWithError error: Error) {
        Task { @MainActor in finish(nil) }
    }
}
#endif
