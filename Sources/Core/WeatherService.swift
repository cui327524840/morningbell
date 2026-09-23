import Combine
import Foundation

enum WeatherError: LocalizedError {
    case badURL
    case cityNotFound(String)
    case network(String)

    var errorDescription: String? {
        switch self {
        case .badURL:
            return "城市名无法解析"
        case .cityNotFound(let name):
            return "没有找到城市「\(name)」，试试换个说法"
        case .network(let message):
            return "天气请求失败：\(message)"
        }
    }
}

final class WeatherService: ObservableObject {
    static let shared = WeatherService()

    @Published var snapshot: WeatherSnapshot?
    @Published var isLoading = false
    @Published var errorText: String?

    private var locationCache: [String: (latitude: Double, longitude: Double, name: String)] = [:]
    private let cacheKey = "morningbell.weather.cache"

    private init() {
        loadCache()
    }

    func refresh(city: String, completion: ((WeatherSnapshot?) -> Void)? = nil) {
        let name = city.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else {
            completion?(snapshot)
            return
        }
        isLoading = true
        errorText = nil
        resolveCity(name) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let location):
                self.fetch(latitude: location.latitude,
                           longitude: location.longitude,
                           cityName: location.name) { snapshot in
                    self.isLoading = false
                    if let snapshot = snapshot {
                        self.snapshot = snapshot
                        self.saveCache(snapshot)
                    }
                    completion?(snapshot ?? self.snapshot)
                }
            case .failure(let error):
                self.isLoading = false
                self.errorText = error.localizedDescription
                completion?(self.snapshot)
            }
        }
    }

    private func resolveCity(_ name: String,
                            completion: @escaping (Result<(latitude: Double, longitude: Double, name: String), Error>) -> Void) {
        if let cached = locationCache[name] {
            completion(.success(cached))
            return
        }
        var components = URLComponents(string: "https://geocoding-api.open-meteo.com/v1/search")
        components?.queryItems = [
            URLQueryItem(name: "name", value: name),
            URLQueryItem(name: "count", value: "1"),
            URLQueryItem(name: "language", value: "zh"),
            URLQueryItem(name: "format", value: "json")
        ]
        guard let url = components?.url else {
            completion(.failure(WeatherError.badURL))
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { [weak self] data, _, error in
            if let error = error {
                DispatchQueue.main.async { completion(.failure(WeatherError.network(error.localizedDescription))) }
                return
            }
            guard let data = data,
                  let decoded = try? JSONDecoder().decode(GeocodingResponse.self, from: data),
                  let place = decoded.results?.first else {
                DispatchQueue.main.async { completion(.failure(WeatherError.cityNotFound(name))) }
                return
            }
            let location = (latitude: place.latitude, longitude: place.longitude, name: place.name)
            DispatchQueue.main.async {
                self?.locationCache[name] = location
                completion(.success(location))
            }
        }.resume()
    }

    private func fetch(latitude: Double,
                       longitude: Double,
                       cityName: String,
                       completion: @escaping (WeatherSnapshot?) -> Void) {
        var components = URLComponents(string: "https://api.open-meteo.com/v1/forecast")
        components?.queryItems = [
            URLQueryItem(name: "latitude", value: String(latitude)),
            URLQueryItem(name: "longitude", value: String(longitude)),
            URLQueryItem(name: "current", value: "temperature_2m,apparent_temperature,weather_code"),
            URLQueryItem(name: "daily", value: "weather_code,temperature_2m_max,temperature_2m_min,precipitation_probability_max"),
            URLQueryItem(name: "timezone", value: "auto"),
            URLQueryItem(name: "forecast_days", value: "1")
        ]
        guard let url = components?.url else {
            completion(nil)
            return
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 15
        URLSession.shared.dataTask(with: request) { data, _, error in
            guard error == nil,
                  let data = data,
                  let decoded = try? JSONDecoder().decode(ForecastResponse.self, from: data) else {
                DispatchQueue.main.async { completion(nil) }
                return
            }
            let current = decoded.current
            let daily = decoded.daily
            // 显式标注类型：?? 链里混了整数字面量时，Swift 会推断成 Any? 而编译失败
            let code: Int = current?.weather_code ?? daily?.weather_code?.first ?? -1
            let high: Double = daily?.temperature_2m_max?.first ?? current?.temperature_2m ?? 0
            let low: Double = daily?.temperature_2m_min?.first ?? current?.temperature_2m ?? 0
            let snapshot = WeatherSnapshot(cityName: cityName,
                                           temperature: current?.temperature_2m ?? high,
                                           apparentTemperature: current?.apparent_temperature ?? current?.temperature_2m ?? high,
                                           weatherCode: code,
                                           description: WeatherCode.describe(code),
                                           high: high,
                                           low: low,
                                           precipitationProbability: daily?.precipitation_probability_max?.first,
                                           updatedAt: Date())
            DispatchQueue.main.async { completion(snapshot) }
        }.resume()
    }

    private func saveCache(_ snapshot: WeatherSnapshot) {
        guard let data = try? JSONEncoder().encode(snapshot) else { return }
        UserDefaults.standard.set(data, forKey: cacheKey)
    }

    private func loadCache() {
        guard let data = UserDefaults.standard.data(forKey: cacheKey),
              let decoded = try? JSONDecoder().decode(WeatherSnapshot.self, from: data) else { return }
        snapshot = decoded
    }
}

private struct GeocodingResponse: Codable {
    struct Place: Codable {
        let name: String
        let latitude: Double
        let longitude: Double
    }
    let results: [Place]?
}

private struct ForecastResponse: Codable {
    struct Current: Codable {
        let temperature_2m: Double?
        let apparent_temperature: Double?
        let weather_code: Int?
    }
    struct Daily: Codable {
        let weather_code: [Int]?
        let temperature_2m_max: [Double]?
        let temperature_2m_min: [Double]?
        let precipitation_probability_max: [Int]?
    }
    let current: Current?
    let daily: Daily?
}
