//
//  SwiftGit2.swift
//
//
//  Created by Mathijs Bernson on 01/03/2024.
//

import Foundation
import Clibgit2

public func SwiftGit2Init() -> Result<Int, NSError> {
    let status = git_libgit2_init()
    if status < 0 {
        return .failure(NSError(gitError: status, pointOfFailure: "git_libgit2_init"))
    }

    // Nothing sets a timeout otherwise -- git_socket_stream__timeout
    // (streams/socket.c) defaults to 0, which libssh2_session_set_timeout
    // treats as "no timeout," so a connection that stalls mid-handshake
    // (rather than cleanly erroring/resetting) hangs forever instead of
    // failing. Both are milliseconds; 0 would mean "use the system
    // default" per common.h's doc comment, which is what left this
    // unbounded in the first place -- these need to be real numbers.
    _ = git2_swift_set_server_connect_timeout(15000)
    _ = git2_swift_set_server_timeout(30000)

    return .success(Int(status))
}

public func SwiftGit2Shutdown() -> Result<Int, NSError> {
    let status = git_libgit2_shutdown()
    if status < 0 {
        return .failure(NSError(gitError: status, pointOfFailure: "git_libgit2_shutdown"))
    } else {
        return .success(Int(status))
    }
}

public func Libgit2Version() -> String {
    var major: Int32 = 0
    var minor: Int32 = 0
    var patch: Int32 = 0
    git_libgit2_version(&major, &minor, &patch)

    let version: String = [major, minor, patch]
        .map(String.init)
        .joined(separator: ".")

    return version
}
