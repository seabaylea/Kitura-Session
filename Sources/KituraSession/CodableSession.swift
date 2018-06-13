/**
 * Copyright IBM Corporation 2018
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Kitura
import LoggerAPI
import KituraContracts

import Foundation

// MARK CodableSession

/**
 A protocol for managing codable user sessions. The user defines a final class with the fields they wish to use within the session. This class can then save or destroy itself from a static `Store`, which is keyed by a `sessionId`. The sessionId can be extracted from the session cookie to initialise an instance of the users class with the session data. If no store is defined, the session will default to an in-memory store.
 __Note__: When using multiple TypeSafeSession classes together, If the cookie names are the same, the cookie secret must also be the same. Otherwise the sessions will conflict and overwrite each others cookies. (Different cookie names can use different secrets)
 */
public protocol CodableSession: Codable {
    
    // MARK: Static type properties
    
    /// Specifies the `Store` for session state, or leave `nil` to use a simple in-memory store.
    /// Note that in-memory stores do not provide support for expiry so should be used for
    /// development and testing purposes only.
    static var store: Store? { get set }
    
    /// A `SessionCookie` that defines the session cookie's name and attributes.
    static var sessionCookie: SessionCookie { get }
    
    // MARK: Mandatory instance properties
    
    /// The unique id for this session.
    var sessionId: String { get }
    
    // MARK: Functions implemented in extension
    
    /// Static getOrCreateSession function that will try and retrieve an instance if Self from the session. It will check the request for the session cookie. If the cookie is not present it will create a cookie and initialize a new session for the user returning the session id. If a session cookie is found, this function will decode and return an instance of itself from the store.
    static func getOrCreateSession(request: RouterRequest, response: RouterResponse, completion: @escaping (Self?, String?, RequestError?) -> Void)
    
    // Add the cookie to the response. Returns true if successful and false if it fails.
    func addCookie(request: RouterRequest, response: RouterResponse) -> Bool
    
    /// Save the current session instance to the store. This also refreshes the expiry.
    /// - Parameter callback: A callback that will be invoked after saving to the store has
    ///                       been attempted, with a parameter describing the error (if one
    ///                       occurred).
    ///                       Any such error will be logged for you, so if you do not want
    ///                       to perform further processing or logic based on the success
    ///                       of this operation, this parameter can be omitted.
    func save(callback: @escaping (Error?) -> Void)
    
    /// Destroy the session, removing it and all its associated data from the store.
    /// - Parameter callback: A callback that will be invoked after removal from the store
    ///                       has been attempted, with a parameter describing the error (if
    ///                       one occurred).
    ///                       Any such error will be logged for you, so if you do not want
    ///                       to perform further processing or logic based on the success
    ///                       of this operation, this parameter can be omitted.
    func destroy(callback: @escaping (Error?) -> Void)
    
    /// Refreshes the expiry of a session in the store. Note that this is done automatically
    /// when a session is restored from a store, but could be repeated if needed (for example,
    /// if the processing of a handler takes a long time and it is desirable to refresh the
    /// expiry before sending the response).
    /// - Parameter callback: A callback that will be invoked after updating the store has
    ///                       been attempted, with a parameter describing the error (if one
    ///                       occurred).
    ///                       Any such error will be logged for you, so if you do not want
    ///                       to perform further processing or logic based on the success
    ///                       of this operation, this parameter can be omitted.
    func touch(callback: @escaping (Error?) -> Void)
}

extension CodableSession {
    
    /// Static getOrCreateSession function that will try and retrieve an instance if Self from the session. It will check the request for the session cookie. If the cookie is not present it will create a cookie and initialize a new session for the user returning the session id. If a session cookie is found, this function will decode and return an instance of itself from the store.
    ///
    /// - Parameter request: The `RouterRequest` object used to get information
    ///                     about the request.
    /// - Parameter response: The `RouterResponse` object used to respond to the
    ///                       request.
    /// - Parameter completion: The closure to invoke once middleware processing
    ///                         is complete. Either an instance of Self, the sessionId or a
    ///                         RequestError should be provided, indicating a
    ///                         retrieving a session, creating a new session or failed attempt to process the request.
    public static func getOrCreateSession(request: RouterRequest, response: RouterResponse, completion: @escaping (Self?, String?, RequestError?) -> Void) {
        // If the user's type has not assigned a store, default to an in-memory store
        let store = Self.store ?? InMemoryStore()
        if Self.store == nil {
            Log.info("No session store was specified by \(Self.self), defaulting to in-memory store.")
            Self.store = store
        }
        guard let (sessionId, newSession) = Self.sessionCookie.cookieManager?.getSessionId(request: request, response: response) else {
            // Failure to initialize CookieCryptography - error logged in cookieConfiguration getter
            return completion(nil, nil, .internalServerError)
        }
        if newSession {
            return completion(nil, sessionId, nil)
        } else {
            // We have a session cookie, now we want to decode a saved CodableSession
            store.load(sessionId: sessionId) { data, error in
                if let error = error {
                    Log.error("Error retreiving session from store: \(error)")
                    return completion(nil, nil, .internalServerError)
                }
                if let data = data {
                    // Refresh the expiry of the session in the store
                    store.touch(sessionId: sessionId) {
                        error in
                        if let error = error {
                            Log.error("Failed to touch session for sessionId=\(sessionId), error: \(error)")
                        }
                    }
                    do {
                        let decoder = JSONDecoder()
                        let selfInstance: Self = try decoder.decode(Self.self, from: data)
                        return completion(selfInstance, nil, nil)
                    } catch {
                        // A serialized session exists in the store, but cannot be decoded. This could occur
                        // if the type has been modified but serialized instances of the old type still exist
                        // in the store.
                        Log.error("Unable to deserialize saved session for sessionId=\(sessionId), error: \(error)")
                        return completion(nil, nil, .internalServerError)
                    }
                } else {
                    // This is okay - a valid cookie was provided but no session could be found in the store.
                    // The session may have timed out, been purged (eg. user logged out) or server was restarted.
                    Log.verbose("Creating new session \(sessionId) as a saved session was not found in the store.")
                    return completion(nil, sessionId, nil)
                }
            }
        }
    }
    
    /**
     Add a cookie to the response
     */
    public func addCookie(request: RouterRequest, response: RouterResponse) -> Bool {
        guard let cookieManager = Self.sessionCookie.cookieManager, cookieManager.addCookie(sessionId: self.sessionId, domain: request.hostname, response: response) else {
            Log.error("Failed to add cookie to response")
            return false
        }
        return true
    }
    
    /**
     Save the current session instance to the store
     ### Usage Example: ###
     ```swift
     router.post("/session") { (session: MySession, name: String, respondWith: (String?, RequestError?) -> Void) in
     session.name = name
     session.save()
     respondWith(session.name, nil)
     }
     ```
     */
    public func save(callback: @escaping (Error?) -> Void = { _ in }) {
        guard let store = Self.store else {
            Log.error("Unexpectedly found a nil store")
            return callback(StoreError.nilStore(message: "Unable to save session: Store is nil"))
        }
        let encoder = JSONEncoder()
        do {
            let selfData: Data = try encoder.encode(self)
            store.save(sessionId: self.sessionId, data: selfData) { error in
                if let error = error {
                    Log.error("Failed to save session data for session: \(self.sessionId), error: \(error)")
                }
                callback(error)
            }
        } catch {
            // The user's type cannot be encoded to JSON using JSONEncoder
            Log.error("Unable to encode \(String(reflecting: Self.self)) for sessionId=\(sessionId), error: \(error)")
            callback(error)
        }
    }
    
    /**
     Destroy the session, removing it and all its associated data from the store
     ### Usage Example: ###
     ```swift
     router.delete("/session") { (session: MySession, respondWith: (RequestError?) -> Void) in
     session.destroy()
     respondWith(nil)
     }
     ```
     */
    public func destroy(callback: @escaping (Error?) -> Void = { _ in }) {
        guard let store = Self.store else {
            Log.error("Unexpectedly found a nil store")
            return callback(StoreError.nilStore(message: "Unable to destroy session: Store is nil"))
        }
        store.delete(sessionId: self.sessionId) { error in
            if let error = error {
                Log.error("Failed to delete session data for sessionId=\(self.sessionId), error: \(error)")
            }
            callback(error)
        }
    }
    
    /// Touch the session, refreshing its expiry time in the store
    public func touch(callback: @escaping (Error?) -> Void = { _ in }) {
        guard let store = Self.store else {
            Log.error("Unexpectedly found a nil store")
            return callback(StoreError.nilStore(message: "Unable to touch session: Store is nil"))
        }
        store.touch(sessionId: self.sessionId) { error in
            if let error = error {
                Log.error("Failed to touch session for sessionId=\(self.sessionId), error: \(error)")
            }
            callback(error)
        }
    }
}
