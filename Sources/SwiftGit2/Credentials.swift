//
//  Credentials.swift
//  SwiftGit2
//
//  Created by Tom Booth on 29/02/2016.
//  Copyright © 2016 GitHub, Inc. All rights reserved.
//

import Clibgit2

private class Wrapper<T> {
	let value: T

	init(_ value: T) {
		self.value = value
	}
}

public enum Credentials {
	case `default`
	case sshAgent
	case plaintext(username: String, password: String)
	case sshMemory(username: String, publicKey: String, privateKey: String, passphrase: String)

	internal static func fromPointer(_ pointer: UnsafeMutableRawPointer) -> Credentials {
		return Unmanaged<Wrapper<Credentials>>.fromOpaque(UnsafeRawPointer(pointer)).takeRetainedValue().value
	}

	internal func toPointer() -> UnsafeMutableRawPointer {
		return Unmanaged.passRetained(Wrapper(self)).toOpaque()
	}
}

/// The actual dispatch from a `Credentials` value to the matching
/// `git_cred_*_new` call, factored out so callback wrappers that source
/// their `Credentials` from a different payload (see Repository.swift's
/// clone-with-progress path, which bundles credentials with a progress
/// block under one retained-for-the-whole-clone context, rather than the
/// single-use-then-freed `Wrapper<Credentials>` below) don't have to
/// duplicate this switch. Converts the result to the error code libgit2
/// expects (0 = success, 1 = rejected setting creds, -1 = error).
internal func performCredentialsCallback(
	_ credentials: Credentials,
	cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
	username: UnsafePointer<CChar>?
) -> Int32 {
	let result: Int32

	// Find username_from_url
	let name = username.map(String.init(cString:))

	switch credentials {
	case .default:
		result = git_cred_default_new(cred)
	case .sshAgent:
		result = git_cred_ssh_key_from_agent(cred, name!)
	case .plaintext(let username, let password):
		result = git_cred_userpass_plaintext_new(cred, username, password)
	case .sshMemory(let username, let publicKey, let privateKey, let passphrase):
		result = git_cred_ssh_key_memory_new(cred, username, publicKey, privateKey, passphrase)
	}

	return (result != GIT_OK.rawValue) ? -1 : 0
}

/// Handle the request of credentials, passing through to a wrapped block after converting the arguments.
internal func credentialsCallback(
	cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
	url: UnsafePointer<CChar>?,
	username: UnsafePointer<CChar>?,
	_: UInt32,
	payload: UnsafeMutableRawPointer? ) -> Int32 {
	return performCredentialsCallback(Credentials.fromPointer(payload!), cred: cred, username: username)
}
