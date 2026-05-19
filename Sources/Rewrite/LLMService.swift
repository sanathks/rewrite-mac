import Foundation

enum LLMError: Error, LocalizedError, Equatable {
    case invalidURL
    case connectionFailed(String)
    case requestFailed(Int)
    case noData
    case decodingFailed(String)

    var errorDescription: String? {
        switch self {
        case .invalidURL:
            return "Invalid server URL. Check your settings."
        case .connectionFailed(let detail):
            return "Cannot connect to LLM server: \(detail)"
        case .requestFailed(let code):
            return "LLM server returned HTTP \(code)."
        case .noData:
            return "No response from LLM server."
        case .decodingFailed(let detail):
            return "Failed to parse LLM server response: \(detail)"
        }
    }
}

final class LLMService {
    static let shared = LLMService()

    /// Short label for the currently-active model. Surfaced in the result
    /// panel's footer so the user can see which engine produced a result.
    static var activeModelLabel: String {
        let settings = Settings.shared
        switch settings.llmProvider {
        case .embedded:
            switch settings.embeddedModel {
            case .e2b4bit: return "gemma-4-E2B"
            case .e4b4bit: return "gemma-4-E4B"
            }
        case .remote:
            return settings.modelName
        }
    }

    let session: URLSession
    let settingsProvider: () -> (serverURL: String, modelName: String)

    init(session: URLSession, settingsProvider: @escaping () -> (serverURL: String, modelName: String)) {
        self.session = session
        self.settingsProvider = settingsProvider
    }

    private convenience init() {
        self.init(session: .shared, settingsProvider: {
            let s = Settings.shared
            return (s.serverURL, s.modelName)
        })
    }

    /// Handle returned by `generateStream` so callers can cancel an in-flight
    /// generation (e.g. when the user dismisses the result panel).
    final class StreamHandle {
        var task: Task<Void, Never>?
        var dataTask: URLSessionDataTask?
        private(set) var isCancelled = false

        func cancel() {
            isCancelled = true
            task?.cancel()
            dataTask?.cancel()
        }
    }

    /// Stream a generation token-by-token. Calls `onChunk` for each chunk on
    /// the main queue, then `onComplete` once when the stream ends (or fails).
    /// Returns a handle the caller can cancel.
    @discardableResult
    func generateStream(
        prompt: String,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<Void, LLMError>) -> Void
    ) -> StreamHandle {
        let handle = StreamHandle()

        if Settings.shared.llmProvider == .embedded {
            handle.task = Task {
                do {
                    let stream = try await EmbeddedLLMService.shared.stream(prompt: prompt)
                    for try await chunk in stream {
                        if Task.isCancelled { break }
                        await MainActor.run { onChunk(chunk) }
                    }
                    await MainActor.run {
                        if handle.isCancelled {
                            onComplete(.success(()))
                        } else {
                            onComplete(.success(()))
                        }
                    }
                } catch let error as LLMError {
                    await MainActor.run { onComplete(.failure(error)) }
                } catch {
                    await MainActor.run {
                        onComplete(.failure(.connectionFailed(error.localizedDescription)))
                    }
                }
            }
            return handle
        }

        // Remote path: OpenAI-compatible SSE streaming.
        streamRemote(prompt: prompt, handle: handle, onChunk: onChunk, onComplete: onComplete)
        return handle
    }

    /// SSE streaming against the OpenAI-compatible /v1/chat/completions
    /// endpoint. Parses `data: {json}\n\n` lines and forwards each
    /// `choices[0].delta.content` to `onChunk`.
    private func streamRemote(
        prompt: String,
        handle: StreamHandle,
        onChunk: @escaping (String) -> Void,
        onComplete: @escaping (Result<Void, LLMError>) -> Void
    ) {
        let settings = settingsProvider()
        guard let url = URL(string: "\(settings.serverURL)/v1/chat/completions") else {
            onComplete(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("text/event-stream", forHTTPHeaderField: "Accept")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": [["role": "user", "content": prompt]],
            "temperature": 0.3,
            "stream": true
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            onComplete(.failure(.decodingFailed(error.localizedDescription)))
            return
        }

        handle.task = Task {
            do {
                let (bytes, response) = try await URLSession.shared.bytes(for: request)
                if let http = response as? HTTPURLResponse, http.statusCode != 200 {
                    await MainActor.run { onComplete(.failure(.requestFailed(http.statusCode))) }
                    return
                }

                for try await line in bytes.lines {
                    if Task.isCancelled { break }
                    // SSE lines look like: "data: {json}" or "data: [DONE]".
                    guard line.hasPrefix("data:") else { continue }
                    let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                    if payload == "[DONE]" { break }
                    guard
                        let data = payload.data(using: .utf8),
                        let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                        let choices = json["choices"] as? [[String: Any]],
                        let delta = choices.first?["delta"] as? [String: Any],
                        let content = delta["content"] as? String,
                        !content.isEmpty
                    else { continue }

                    await MainActor.run { onChunk(content) }
                }
                await MainActor.run { onComplete(.success(())) }
            } catch {
                if Task.isCancelled {
                    await MainActor.run { onComplete(.success(())) }
                } else {
                    await MainActor.run {
                        onComplete(.failure(.connectionFailed(error.localizedDescription)))
                    }
                }
            }
        }
    }

    func generate(prompt: String, completion: @escaping (Result<String, LLMError>) -> Void) {
        // Route to the on-device pipeline when the embedded provider is active.
        // The remote (OpenAI-compatible) path below is preserved as a fallback.
        if Settings.shared.llmProvider == .embedded {
            Task {
                do {
                    let text = try await EmbeddedLLMService.shared.generate(prompt: prompt)
                    completion(.success(text))
                } catch let error as LLMError {
                    completion(.failure(error))
                } catch {
                    completion(.failure(.connectionFailed(error.localizedDescription)))
                }
            }
            return
        }

        let settings = settingsProvider()
        guard let url = URL(string: "\(settings.serverURL)/v1/chat/completions") else {
            completion(.failure(.invalidURL))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 120

        let body: [String: Any] = [
            "model": settings.modelName,
            "messages": [
                ["role": "user", "content": prompt]
            ],
            "temperature": 0.3,
            "stream": false
        ]

        do {
            request.httpBody = try JSONSerialization.data(withJSONObject: body)
        } catch {
            completion(.failure(.decodingFailed(error.localizedDescription)))
            return
        }

        let task = session.dataTask(with: request) { data, response, error in
            if let error = error {
                completion(.failure(.connectionFailed(error.localizedDescription)))
                return
            }

            if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                completion(.failure(.requestFailed(httpResponse.statusCode)))
                return
            }

            guard let data = data else {
                completion(.failure(.noData))
                return
            }

            guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let choices = json["choices"] as? [[String: Any]],
                  let first = choices.first,
                  let message = first["message"] as? [String: Any],
                  let content = message["content"] as? String else {
                completion(.failure(.noData))
                return
            }

            completion(.success(content.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        task.resume()
    }

    func fetchModels(completion: @escaping ([String]) -> Void) {
        // Embedded provider has no remote model list — the UI shows the
        // Gemma 4 picker directly.
        if Settings.shared.llmProvider == .embedded {
            completion([])
            return
        }

        let settings = settingsProvider()
        guard let url = URL(string: "\(settings.serverURL)/v1/models") else {
            completion([])
            return
        }

        var request = URLRequest(url: url)
        request.timeoutInterval = 5

        session.dataTask(with: request) { data, response, _ in
            guard let data = data,
                  let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200,
                  let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let models = json["data"] as? [[String: Any]] else {
                completion([])
                return
            }
            let names = models.compactMap { $0["id"] as? String }.sorted()
            completion(names)
        }.resume()
    }
}
