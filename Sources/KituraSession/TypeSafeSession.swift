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

// MARK TypeSafeSession

/**
 A `TypeSafeMiddleware` for managing user sessions. The user defines a final class with the fields they wish to use within  the session. This class can then save or destroy itself from a static `Store`, which is keyed by a `sessionId`. The sessionId can be extracted from the session cookie to initialise an instance of the users class with the session data. If no store is defined, the session will default to an in-memory store.
 ### Usage Example: ###
 In this example, a class conforming to the TypeSafeSession protocol is defined containing an optional "name" field. Then a route on "/session" is set up that stores a received name into the session.
 ```swift
 final class MySession: TypeSafeSession {
    var name: String?
 
    let sessionId: String
    init(sessionId: String) {
        self.sessionId = sessionId
    }
     static var store: Store?
     static let sessionCookie = SessionCookie(name: "session-cookie", secret: "abc123")
 }
 
 router.post("/session") { (session: MySession, name: String, respondWith: (String?, RequestError?) -> Void) in
    session.name = name
    try? session.save()
    respondWith(session.name, nil)
 }
 ```
 __Note__: When using multiple TypeSafeSession classes together, If the cookie names are the same, the cookie secret must also be the same. Otherwise the sessions will conflict and overwrite each others cookies. (Different cookie names can use different secrets)
 */
public protocol TypeSafeSession: TypeSafeMiddleware, CodableSession {

    /// Create a new instance (an empty session), where the only known value is the
    /// (newly created) session id. Non-optional fields must be given a default value.
    ///
    /// Existing sessions are restored via the Codable API by decoding a retreived JSON
    /// representation.
    init(sessionId: String)
}

extension TypeSafeSession {

    /// Static handle function that will try and create an instance if Self. It will check the request for the session cookie. If the cookie is not present it will create a cookie and initialize a new session for the user. If a session cookie is found, this function will decode and return an instance of itself from the store.
    ///
    /// - Parameter request: The `RouterRequest` object used to get information
    ///                     about the request.
    /// - Parameter response: The `RouterResponse` object used to respond to the
    ///                       request.
    /// - Parameter completion: The closure to invoke once middleware processing
    ///                         is complete. Either an instance of Self or a
    ///                         RequestError should be provided, indicating a
    ///                         successful or failed attempt to process the request.
    public static func handle(request: RouterRequest, response: RouterResponse, completion: @escaping (Self?, RequestError?) -> Void) {
        
        getOrCreateSession(request: request, response: response) { (userProfile, sessionId, error) in
            if let sessionId = sessionId {
                let newSession = Self(sessionId: sessionId)
                if (newSession.addCookie(request: request, response: response)) {
                    completion(Self(sessionId: sessionId), nil)
                } else {
                    completion(nil, .internalServerError)
                }
            } else if let userProfile = userProfile {
                completion(userProfile, nil)
            } else {
                completion(nil, error)
            }
        }
    }
}
