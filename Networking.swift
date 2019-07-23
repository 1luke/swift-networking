//  MIT License
//
//  Copyright (c) 2019 Luke
//
//  Permission is hereby granted, free of charge, to any person obtaining a copy
//  of this software and associated documentation files (the "Software"), to deal
//  in the Software without restriction, including without limitation the rights
//  to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
//  copies of the Software, and to permit persons to whom the Software is
//  furnished to do so, subject to the following conditions:
//
//  The above copyright notice and this permission notice shall be included in all
//  copies or substantial portions of the Software.
//
//  THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
//  IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
//  FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
//  AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
//  LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
//  OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
//  SOFTWARE.

import Foundation

public typealias DataTaskResponse = (data: Data?, urlResponse: URLResponse?, error: Error?)

/// Object containing JSON decoding properties. e.g. `JSONDecoder`.
///
/// JSON fetch operation will retain decoder and queues based on the parameter
/// `shouldRetainDecoder` for a given fetch operation.
///
public protocol JSONDecodeDelegate {
    var jsonDecoder: JSONDecoder { get }
    var decodeQueue: DispatchQueue { get }
    var callbackQueue: DispatchQueue { get }
}

/// Abstract error type of `URLSession` `dataTask` operation. Initializable from decode
/// failure and bad data-task response (e.g. error status code) based on internal-logic.
///
/// JSON fetch operation requires this error type to support generic decoding with
/// _custom_ error types. Use `AnyFetchError` for a general common implementation.
///
public protocol DataTaskError: Error {
    /// Return the _error_ associated with decoding failure.
    ///
    /// Provides `DataTaskResponse` typically for logging.
    init(decodeError: Error, rawResponse: DataTaskResponse)

    /// Return result, `data` or `error` (of type `Self`), from given `DataTaskResponse`.
    ///
    /// Evaluate `DataTaskResponse` (e.g. check status code) to determine result.
    /// - Parameter rawResponse: Data task response: `(Data?, URLResponse?, Error?)`
    static func extract(rawResponse: DataTaskResponse) -> Result<Data, Self>
}

// MARK: - URLSession

public extension URLSession {
    /// Fetch JSON executing given `request`. Set `shouldRetainDecoder` to **true**
    /// if the session should keep decoder and operation queues in memory. Default is **false**,
    /// i.e. response is ignored if the _delegate_ is deallocated at network callback.
    ///
    func fetchJson<Response: Decodable, Error: DataTaskError>(
        with request: URLRequest,
        decodeDelegate delegate: JSONDecodeDelegate,
        shouldRetainDecoder: Bool = false,
        callback _callback: @escaping (Result<Response, Error>) -> Void) {
        
        weak var jsonDecoder = delegate.jsonDecoder
        weak var decodeQueue = delegate.decodeQueue
        weak var callbackQueue = delegate.callbackQueue

        /// Retain decode properties accordingly
        var retained: (decoder: JSONDecoder?, DispatchQueue?, DispatchQueue?)
        if shouldRetainDecoder {
            retained = (delegate.jsonDecoder, delegate.decodeQueue, delegate.callbackQueue)
        }

        let callback: (Result<Response, Error>) -> Void = { result in
            callbackQueue?.async { _callback(result) }
        }
        
        dataTask(with: request) {
            let response = ($0, $1, $2)
            decodeQueue?.async {
                let decoder = retained.decoder ?? jsonDecoder
                decoder?.decode(response, callback: callback)
            }
        }.resume()
    }

}

// MARK: - JSONDecoder

public extension JSONDecoder {
    func decode<Response: Decodable, Error: DataTaskError>(
        _ response: DataTaskResponse,
        callback: @escaping (Result<Response, Error>) -> Void) {

        switch Error.extract(rawResponse: response) {
        case .success(let json):
            do {
                let decoded = try decode(Response.self, from: json)
                callback(.success(decoded))
            } catch let error {
                callback(.failure(Error(decodeError: error, rawResponse: response)))
            }
        case .failure(let error):
            callback(.failure(error))
        }
    }

}

// MARK: - HTTP Methods

enum HTTPMethod: String {
    case get = "GET"
    case put = "PUT"
    case post = "POST"
    case delete = "DELETE"
    case patch = "PATCH"
}

// MARK: - Network Error

/// Unmatching coding types or network issues
public enum BadRequest: Error {
    case encode(Error)
    case decode(Error)
    case noData
    case noURLResponse
}

/// Any data-fetch failure (bad request or error status code: ~= 200...299)
public enum AnyFetchError: DataTaskError {
    case badRequest(BadRequest)
    case statusCode(Int, rawResponse: DataTaskResponse)
    
    // MARK: DataTaskError
    
    public init(decodeError error: Error, rawResponse: DataTaskResponse) {
        self = .badRequest(.decode(error))
    }
    
    public static func extract(rawResponse: DataTaskResponse) -> Result<Data, AnyFetchError> {
        guard let urlResponse = rawResponse.urlResponse as? HTTPURLResponse else {
            return .failure(.badRequest(.noURLResponse))
        }
        guard 200...299 ~= urlResponse.statusCode else {
            return .failure(.statusCode(urlResponse.statusCode, rawResponse: rawResponse))
        }
        guard let data = rawResponse.data else {
            return .failure(.badRequest(.noData))
        }
        return .success(data)
    }
}

// MARK: Helpers

extension URLRequest {
    init(for url: URL, method: HTTPMethod, headers: [String : String]) {
        self.init(url: url)
        httpMethod = method.rawValue
        headers.forEach { key, value in
            setValue(value, forHTTPHeaderField: key)
        }
    }

}

public extension URL {
    func appending(path: String) -> URL? {
        var path = path
        if path.first == "/" { path.removeFirst() }
        guard let url = URL(string: path, relativeTo: self) else {
            return nil
        }
        return url
    }

}

extension DataTaskError {
    static func describe(_ rawResponse: DataTaskResponse) -> String {
        return """
        error: \(rawResponse.error?.localizedDescription ?? "…") -- urlResponse: \(rawResponse.urlResponse?.debugDescription ?? "…") -- data: \(rawResponse.data == nil ? "…" : String(data: rawResponse.data!, encoding: .utf8) ?? " -- data-unknown -\n \(rawResponse.data!)")
        """
    }
}
