//
//  ObjCExceptionCatcher.swift
//  AppAgent
//
//  Swift-friendly wrapper over AppAgentObjCSupport's NSException catcher.
//  Used by runtime-inspection tools so a bad KVC key path or reflection call
//  raises a Swift error instead of crashing the host process.
//

import Foundation
#if canImport(AppAgentObjCSupport)
// SwiftPM build: the ObjC catcher lives in its own module.
import AppAgentObjCSupport
#endif
// Xcode app builds (e.g. the demo) compile the ObjC source directly into the
// app target and expose `AppAgentObjCExceptionCatcher` via a bridging header,
// so no module import is available or needed there.

enum ObjCExceptionCatcher {
    /// Run a block, converting any raised NSException into a thrown Swift error.
    static func perform(_ block: () -> Void) throws {
        try AppAgentObjCExceptionCatcher.catchException(block)
    }

    /// Run a value-returning block with the same NSException protection.
    static func performReturning<T>(_ block: () -> T) throws -> T {
        var result: T!
        try AppAgentObjCExceptionCatcher.catchException {
            result = block()
        }
        return result
    }
}
