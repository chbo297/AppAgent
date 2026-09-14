//
//  AsyncStreamCompat.swift
//  AppAgent
//

import Foundation

extension AsyncStream {
    /// Create a (stream, continuation) pair with backward compatibility for iOS < 17.
    static func makePair() -> (stream: AsyncStream, continuation: Continuation) {
        if #available(iOS 17.0, macOS 14.0, *) {
            return makeStream()
        } else {
            var cont: Continuation!
            let stream = AsyncStream { cont = $0 }
            return (stream, cont)
        }
    }
}
