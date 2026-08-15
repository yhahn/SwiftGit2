//
//  Repository.swift
//  SwiftGit2
//
//  Created by Matt Diephouse on 11/7/14.
//  Copyright (c) 2014 GitHub, Inc. All rights reserved.
//

import Foundation
import Clibgit2

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

public typealias CheckoutProgressBlock = (String?, Int, Int) -> Void

/// Helper function used as the libgit2 progress callback in git_checkout_options.
/// This is a function with a type signature of git_checkout_progress_cb.
private func checkoutProgressCallback(path: UnsafePointer<Int8>?, completedSteps: Int, totalSteps: Int,
                                      payload: UnsafeMutableRawPointer?) {
	if let payload = payload {
		let buffer = payload.assumingMemoryBound(to: CheckoutProgressBlock.self)
		let block: CheckoutProgressBlock
		if completedSteps < totalSteps {
			block = buffer.pointee
		} else {
			block = buffer.move()
			buffer.deallocate()
		}
		block(path.flatMap(String.init(validatingUTF8:)), completedSteps, totalSteps)
	}
}

/// Helper function for initializing libgit2 git_checkout_options.
///
/// :param: strategy The strategy to be used when checking out the repo, see CheckoutStrategy
/// :param: progress A block that's called with the progress of the checkout.
/// :returns: Returns a git_checkout_options struct with the progress members set.
private func checkoutOptions(strategy: CheckoutStrategy,
                             progress: CheckoutProgressBlock? = nil) -> git_checkout_options {
	// Do this because GIT_CHECKOUT_OPTIONS_INIT is unavailable in swift
	let pointer = UnsafeMutablePointer<git_checkout_options>.allocate(capacity: 1)
	git_checkout_init_options(pointer, UInt32(GIT_CHECKOUT_OPTIONS_VERSION))
	var options = pointer.move()
	pointer.deallocate()

	options.checkout_strategy = strategy.gitCheckoutStrategy.rawValue

	if progress != nil {
		options.progress_cb = checkoutProgressCallback
		let blockPointer = UnsafeMutablePointer<CheckoutProgressBlock>.allocate(capacity: 1)
		blockPointer.initialize(to: progress!)
		options.progress_payload = UnsafeMutableRawPointer(blockPointer)
	}

	return options
}

/// Accepts any host key with no verification against a known-hosts store.
/// There's no `~/.ssh/known_hosts` on iOS, and without *some*
/// `certificate_check` callback registered, libgit2's SSH transport
/// rejects every host outright ("invalid or unknown remote ssh hostkey" --
/// see ssh_libssh2.c's `check_certificate`, which only trusts a host when
/// either a known-hosts match or a non-NULL callback says so). This is a
/// real, deliberate simplification, not an oversight: no TOFU, no pinning,
/// no way for a caller to review or reject an unexpected host key. A real
/// fix needs a known-hosts store the app can persist and let the user
/// inspect, which nothing here provides yet.
private func acceptAnyCertificateCallback(
	cert: UnsafeMutablePointer<git_cert>?,
	valid: Int32,
	host: UnsafePointer<CChar>?,
	payload: UnsafeMutableRawPointer?
) -> Int32 {
	return 0
}

/// (receivedObjects, totalObjects, receivedBytes) -- the same fields
/// `git clone`'s own "Receiving objects: N% (x/y), z bytes" line reports,
/// straight from libgit2's git_indexer_progress.
public typealias FetchProgressBlock = (Int, Int, Int) -> Void

/// git_remote_callbacks has exactly one shared `payload` for every
/// callback registered on it (credentials, certificate_check,
/// transfer_progress, ...) -- unlike git_checkout_options, which gives
/// progress its own independent payload field. Credentials.toPointer()'s
/// `Wrapper<Credentials>` is consumed (freed) the first time
/// `credentialsCallback` runs, which is fine when it's the only callback
/// reading that payload -- but transfer_progress can fire dozens of times
/// over one clone, and credentials can legitimately be re-requested during
/// auth negotiation, so a payload usable only once isn't safe to share
/// between them. This context is retained for the whole clone instead,
/// and the caller (`Repository.clone`) explicitly releases it via `defer`
/// once git_clone returns, rather than relying on a callback's last
/// invocation to free it -- correct even if progress is nil or the clone
/// fails before any progress callback ever fires.
private final class CloneCallbackContext {
	let credentials: Credentials
	let progress: FetchProgressBlock?

	init(credentials: Credentials, progress: FetchProgressBlock?) {
		self.credentials = credentials
		self.progress = progress
	}
}

private func cloneCredentialsCallback(
	cred: UnsafeMutablePointer<UnsafeMutablePointer<git_cred>?>?,
	url: UnsafePointer<CChar>?,
	username: UnsafePointer<CChar>?,
	_: UInt32,
	payload: UnsafeMutableRawPointer?
) -> Int32 {
	guard let payload else { return -1 }
	let context = Unmanaged<CloneCallbackContext>.fromOpaque(payload).takeUnretainedValue()
	return performCredentialsCallback(context.credentials, cred: cred, username: username)
}

private func cloneTransferProgressCallback(
	stats: UnsafePointer<git_indexer_progress>?,
	payload: UnsafeMutableRawPointer?
) -> Int32 {
	guard let payload, let stats else { return 0 }
	let context = Unmanaged<CloneCallbackContext>.fromOpaque(payload).takeUnretainedValue()
	context.progress?(Int(stats.pointee.received_objects), Int(stats.pointee.total_objects), Int(stats.pointee.received_bytes))
	return 0
}

private func cloneFetchOptions(payload: UnsafeMutableRawPointer) -> git_fetch_options {
	let pointer = UnsafeMutablePointer<git_fetch_options>.allocate(capacity: 1)
	git_fetch_init_options(pointer, UInt32(GIT_FETCH_OPTIONS_VERSION))

	var options = pointer.move()

	pointer.deallocate()

	options.callbacks.payload = payload
	options.callbacks.credentials = cloneCredentialsCallback
	options.callbacks.certificate_check = acceptAnyCertificateCallback
	options.callbacks.transfer_progress = cloneTransferProgressCallback

	return options
}

private func fetchOptions(credentials: Credentials) -> git_fetch_options {
	let pointer = UnsafeMutablePointer<git_fetch_options>.allocate(capacity: 1)
	git_fetch_init_options(pointer, UInt32(GIT_FETCH_OPTIONS_VERSION))

	var options = pointer.move()

	pointer.deallocate()

	options.callbacks.payload = credentials.toPointer()
	options.callbacks.credentials = credentialsCallback
	options.callbacks.certificate_check = acceptAnyCertificateCallback

	return options
}

private func pushOptions(credentials: Credentials) -> git_push_options {
	let pointer = UnsafeMutablePointer<git_push_options>.allocate(capacity: 1)
	git_push_init_options(pointer, UInt32(GIT_PUSH_OPTIONS_VERSION))

	var options = pointer.move()

	pointer.deallocate()

	options.callbacks.payload = credentials.toPointer()
	options.callbacks.credentials = credentialsCallback
	options.callbacks.certificate_check = acceptAnyCertificateCallback

	return options
}

/// Build a `git_strarray` from Swift strings for the duration of `body`, freeing the
/// C strings it allocates afterward. libgit2 only reads from the array during the
/// call, so this narrower lifetime (vs. `git_strarray_free`, meant for arrays libgit2
/// itself allocated) is the right match.
private func withGitStrArray<T>(_ strings: [String], _ body: (inout git_strarray) -> T) -> T {
	var cStrings: [UnsafeMutablePointer<Int8>?] = strings.map { strdup($0) }
	defer { cStrings.forEach { free($0) } }
	return cStrings.withUnsafeMutableBufferPointer { buffer in
		var strarray = git_strarray(strings: buffer.baseAddress, count: buffer.count)
		return body(&strarray)
	}
}

private func cloneOptions(bare: Bool = false, localClone: Bool = false, fetchOptions: git_fetch_options? = nil,
                          checkoutOptions: git_checkout_options? = nil) -> git_clone_options {
	let pointer = UnsafeMutablePointer<git_clone_options>.allocate(capacity: 1)
	git_clone_init_options(pointer, UInt32(GIT_CLONE_OPTIONS_VERSION))

	var options = pointer.move()

	pointer.deallocate()

	options.bare = bare ? 1 : 0

	if localClone {
		options.local = GIT_CLONE_NO_LOCAL
	}

	if let checkoutOptions = checkoutOptions {
		options.checkout_opts = checkoutOptions
	}

	if let fetchOptions = fetchOptions {
		options.fetch_opts = fetchOptions
	}

	return options
}

/// A git repository.
public final class Repository {

	// MARK: - Creating Repositories

	/// Create a new repository at the given URL.
	///
	/// URL  - The URL of the repository.
	/// bare - Create a bare repository (no working directory) -- what a push
	///        target needs to be, since pushing to a checked-out branch on a
	///        non-bare repository is refused (or leaves the working directory
	///        out of sync with HEAD, depending on transport).
	///
	/// Returns a `Result` with a `Repository` or an error.
	public class func create(at url: URL, bare: Bool = false) -> Result<Repository, NSError> {
		var pointer: OpaquePointer? = nil
		let result = url.withUnsafeFileSystemRepresentation {
			git_repository_init(&pointer, $0, bare ? 1 : 0)
		}

		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_repository_init"))
		}

		let repository = Repository(pointer!)
		return Result.success(repository)
	}

	/// Load the repository at the given URL.
	///
	/// URL - The URL of the repository.
	///
	/// Returns a `Result` with a `Repository` or an error.
	public class func at(_ url: URL) -> Result<Repository, NSError> {
		var pointer: OpaquePointer? = nil
		let result = url.withUnsafeFileSystemRepresentation {
			git_repository_open(&pointer, $0)
		}

		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_repository_open"))
		}

		let repository = Repository(pointer!)
		return Result.success(repository)
	}

	/// Clone the repository from a given URL.
	///
	/// remoteURL        - The URL of the remote repository
	/// localURL         - The URL to clone the remote repository into
	/// localClone       - Will not bypass the git-aware transport, even if remote is local.
	/// bare             - Clone remote as a bare repository.
	/// credentials      - Credentials to be used when connecting to the remote.
	/// checkoutStrategy - The checkout strategy to use, if being checked out.
	/// checkoutProgress - A block that's called with the progress of the checkout.
	/// fetchProgress    - A block that's called with the progress of the network transfer
	///                    (objects received/total, bytes received) -- the phase that actually
	///                    dominates a clone's wall-clock time, unlike checkout.
	///
	/// Returns a `Result` with a `Repository` or an error.
	public class func clone(from remoteURL: URL, to localURL: URL, localClone: Bool = false, bare: Bool = false,
	                        credentials: Credentials = .default, checkoutStrategy: CheckoutStrategy = .Safe,
	                        checkoutProgress: CheckoutProgressBlock? = nil,
	                        fetchProgress: FetchProgressBlock? = nil) -> Result<Repository, NSError> {
		let context = CloneCallbackContext(credentials: credentials, progress: fetchProgress)
		let contextPointer = Unmanaged.passRetained(context).toOpaque()
		defer { Unmanaged<CloneCallbackContext>.fromOpaque(contextPointer).release() }

		var options = cloneOptions(
			bare: bare,
			localClone: localClone,
			fetchOptions: cloneFetchOptions(payload: contextPointer),
			checkoutOptions: checkoutOptions(strategy: checkoutStrategy, progress: checkoutProgress))

		var pointer: OpaquePointer? = nil
		// isFileReferenceURL() is an Apple-only NSURL concept (a URL that
		// tracks file identity across renames, distinct from an ordinary
		// file:// URL) with no equivalent in swift-corelibs-foundation on
		// Linux. absoluteString alone is a valid git remote string for
		// both file:// and remote URLs, so it's the portable fallback.
		#if canImport(ObjectiveC)
		let remoteURLString = (remoteURL as NSURL).isFileReferenceURL() ? remoteURL.path : remoteURL.absoluteString
		#else
		let remoteURLString = remoteURL.absoluteString
		#endif
		let result = localURL.withUnsafeFileSystemRepresentation { localPath in
			git_clone(&pointer, remoteURLString, localPath, &options)
		}

		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_clone"))
		}

		let repository = Repository(pointer!)
		return Result.success(repository)
	}

	// MARK: - Initializers

	/// Create an instance with a libgit2 `git_repository` object.
	///
	/// The Repository assumes ownership of the `git_repository` object.
	public init(_ pointer: OpaquePointer) {
		self.pointer = pointer

		let path = git_repository_workdir(pointer)
		self.directoryURL = path.map({ URL(fileURLWithPath: String(validatingUTF8: $0)!, isDirectory: true) })
	}

	deinit {
		git_repository_free(pointer)
	}

	// MARK: - Properties

	/// The underlying libgit2 `git_repository` object.
	public let pointer: OpaquePointer

	/// The URL of the repository's working directory, or `nil` if the
	/// repository is bare.
	public let directoryURL: URL?

	// MARK: - Object Lookups

	/// Load a libgit2 object and transform it to something else.
	///
	/// oid       - The OID of the object to look up.
	/// type      - The type of the object to look up.
	/// transform - A function that takes the libgit2 object and transforms it
	///             into something else.
	///
	/// Returns the result of calling `transform` or an error if the object
	/// cannot be loaded.
	private func withGitObject<T>(_ oid: OID, type: git_object_t,
	                              transform: (OpaquePointer) -> Result<T, NSError>) -> Result<T, NSError> {
		var pointer: OpaquePointer? = nil
		var oid = oid.oid
		let result = git_object_lookup(&pointer, self.pointer, &oid, type)

		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_object_lookup"))
		}

		let value = transform(pointer!)
		git_object_free(pointer)
		return value
	}

	private func withGitObject<T>(_ oid: OID, type: git_object_t, transform: (OpaquePointer) -> T) -> Result<T, NSError> {
		return withGitObject(oid, type: type) { Result.success(transform($0)) }
	}

	private func withGitObjects<T>(_ oids: [OID], type: git_object_t, transform: ([OpaquePointer]) -> Result<T, NSError>) -> Result<T, NSError> {
		var pointers = [OpaquePointer]()
		defer {
			for pointer in pointers {
				git_object_free(pointer)
			}
		}

		for oid in oids {
			var pointer: OpaquePointer? = nil
			var oid = oid.oid
			let result = git_object_lookup(&pointer, self.pointer, &oid, type)

			guard result == GIT_OK.rawValue else {
				return Result.failure(NSError(gitError: result, pointOfFailure: "git_object_lookup"))
			}

			pointers.append(pointer!)
		}

		return transform(pointers)
	}

	/// Loads the object with the given OID.
	///
	/// oid - The OID of the blob to look up.
	///
	/// Returns a `Blob`, `Commit`, `Tag`, or `Tree` if one exists, or an error.
	public func object(_ oid: OID) -> Result<ObjectType, NSError> {
		return withGitObject(oid, type: GIT_OBJECT_ANY) { object in
			let type = git_object_type(object)
			if type == Blob.type {
				return Result.success(Blob(object))
			} else if type == Commit.type {
				return Result.success(Commit(object))
			} else if type == Tag.type {
				return Result.success(Tag(object))
			} else if type == Tree.type {
				return Result.success(Tree(object))
			}

			let error = NSError(
				domain: "org.libgit2.SwiftGit2",
				code: 1,
				userInfo: [
					NSLocalizedDescriptionKey: "Unrecognized git_object_t '\(type)' for oid '\(oid)'.",
				]
			)
			return Result.failure(error)
		}
	}

	/// Loads the blob with the given OID.
	///
	/// oid - The OID of the blob to look up.
	///
	/// Returns the blob if it exists, or an error.
	public func blob(_ oid: OID) -> Result<Blob, NSError> {
		return withGitObject(oid, type: GIT_OBJECT_BLOB) { Blob($0) }
	}

	/// Loads the commit with the given OID.
	///
	/// oid - The OID of the commit to look up.
	///
	/// Returns the commit if it exists, or an error.
	public func commit(_ oid: OID) -> Result<Commit, NSError> {
		return withGitObject(oid, type: GIT_OBJECT_COMMIT) { Commit($0) }
	}

	/// Loads the tag with the given OID.
	///
	/// oid - The OID of the tag to look up.
	///
	/// Returns the tag if it exists, or an error.
	public func tag(_ oid: OID) -> Result<Tag, NSError> {
		return withGitObject(oid, type: GIT_OBJECT_TAG) { Tag($0) }
	}

	/// Loads the tree with the given OID.
	///
	/// oid - The OID of the tree to look up.
	///
	/// Returns the tree if it exists, or an error.
	public func tree(_ oid: OID) -> Result<Tree, NSError> {
		return withGitObject(oid, type: GIT_OBJECT_TREE) { Tree($0) }
	}

	/// Loads the referenced object from the pointer.
	///
	/// pointer - A pointer to an object.
	///
	/// Returns the object if it exists, or an error.
	public func object<T>(from pointer: PointerTo<T>) -> Result<T, NSError> {
		return withGitObject(pointer.oid, type: pointer.type) { T($0) }
	}

	/// Loads the referenced object from the pointer.
	///
	/// pointer - A pointer to an object.
	///
	/// Returns the object if it exists, or an error.
	public func object(from pointer: Pointer) -> Result<ObjectType, NSError> {
		switch pointer {
		case let .blob(oid):
			return blob(oid).map { $0 as ObjectType }
		case let .commit(oid):
			return commit(oid).map { $0 as ObjectType }
		case let .tag(oid):
			return tag(oid).map { $0 as ObjectType }
		case let .tree(oid):
			return tree(oid).map { $0 as ObjectType }
		}
	}

	// MARK: - Remote Lookups

	/// Loads all the remotes in the repository.
	///
	/// Returns an array of remotes, or an error.
	public func allRemotes() -> Result<[Remote], NSError> {
		let pointer = UnsafeMutablePointer<git_strarray>.allocate(capacity: 1)
		let result = git_remote_list(pointer, self.pointer)

		guard result == GIT_OK.rawValue else {
			pointer.deallocate()
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_remote_list"))
		}

		let strarray = pointer.pointee
		let remotes: [Result<Remote, NSError>] = strarray.map {
			return self.remote(named: $0)
		}
		git_strarray_free(pointer)
		pointer.deallocate()

		return remotes.aggregateResult()
	}

	private func remoteLookup<A>(named name: String, _ callback: (Result<OpaquePointer, NSError>) -> A) -> A {
		var pointer: OpaquePointer? = nil
		defer { git_remote_free(pointer) }

		let result = git_remote_lookup(&pointer, self.pointer, name)

		guard result == GIT_OK.rawValue else {
			return callback(.failure(NSError(gitError: result, pointOfFailure: "git_remote_lookup")))
		}

		return callback(.success(pointer!))
	}

	/// Load a remote from the repository.
	///
	/// name - The name of the remote.
	///
	/// Returns the remote if it exists, or an error.
	public func remote(named name: String) -> Result<Remote, NSError> {
		return remoteLookup(named: name) { $0.map(Remote.init) }
	}

	/// Download new data and update tips
	public func fetch(_ remote: Remote) -> Result<(), NSError> {
		return remoteLookup(named: remote.name) { remote in
			remote.flatMap { pointer in
				var opts = git_fetch_options()
				let resultInit = git_fetch_init_options(&opts, UInt32(GIT_FETCH_OPTIONS_VERSION))
				assert(resultInit == GIT_OK.rawValue)

				let result = git_remote_fetch(pointer, nil, &opts, nil)
				guard result == GIT_OK.rawValue else {
					let err = NSError(gitError: result, pointOfFailure: "git_remote_fetch")
					return .failure(err)
				}
				return .success(())
			}
		}
	}

	/// Download new data and update tips, authenticating with the given credentials.
	/// `fetch(_:)` above has no way to do this -- it always builds fetch options with
	/// no credentials callback wired up, so it only works against a remote that needs
	/// no auth.
	public func fetch(_ remote: Remote, credentials: Credentials) -> Result<(), NSError> {
		return remoteLookup(named: remote.name) { remote in
			remote.flatMap { pointer in
				var opts = fetchOptions(credentials: credentials)

				let result = git_remote_fetch(pointer, nil, &opts, nil)
				guard result == GIT_OK.rawValue else {
					let err = NSError(gitError: result, pointOfFailure: "git_remote_fetch")
					return .failure(err)
				}
				return .success(())
			}
		}
	}

	/// Register a new remote in the repository's configuration.
	public func addRemote(name: String, url: String) -> Result<Remote, NSError> {
		var pointer: OpaquePointer? = nil
		let result = git_remote_create(&pointer, self.pointer, name, url)
		guard result == GIT_OK.rawValue, let pointer else {
			return .failure(NSError(gitError: result, pointOfFailure: "git_remote_create"))
		}
		defer { git_remote_free(pointer) }
		return .success(Remote(pointer))
	}

	/// Push refspecs (e.g. "refs/heads/main:refs/heads/main") to the remote,
	/// authenticating with the given credentials.
	public func push(_ remote: Remote, refspecs: [String], credentials: Credentials) -> Result<(), NSError> {
		return remoteLookup(named: remote.name) { remote in
			remote.flatMap { pointer in
				var opts = pushOptions(credentials: credentials)
				let result = withGitStrArray(refspecs) { strarray in
					git_remote_push(pointer, &strarray, &opts)
				}
				guard result == GIT_OK.rawValue else {
					let err = NSError(gitError: result, pointOfFailure: "git_remote_push")
					return .failure(err)
				}
				return .success(())
			}
		}
	}

	/// Whether `descendant` has `ancestor` in its history -- i.e. moving a branch
	/// pointer from `ancestor` to `descendant` is a fast-forward, losing no commits.
	/// Matches `git_graph_descendant_of`'s semantics: a commit is not its own
	/// descendant, so this is `false` when the two OIDs are equal (already
	/// up to date, not "safe to fast-forward" as a distinct case worth conflating).
	public func isDescendant(_ descendant: OID, of ancestor: OID) -> Result<Bool, NSError> {
		var descendantOid = descendant.oid
		var ancestorOid = ancestor.oid
		let result = git_graph_descendant_of(self.pointer, &descendantOid, &ancestorOid)
		guard result == 0 || result == 1 else {
			return .failure(NSError(gitError: result, pointOfFailure: "git_graph_descendant_of"))
		}
		return .success(result == 1)
	}

	// MARK: - Reference Lookups

	/// Load all the references with the given prefix (e.g. "refs/heads/")
	public func references(withPrefix prefix: String) -> Result<[ReferenceType], NSError> {
		let pointer = UnsafeMutablePointer<git_strarray>.allocate(capacity: 1)
		let result = git_reference_list(pointer, self.pointer)

		guard result == GIT_OK.rawValue else {
			pointer.deallocate()
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_reference_list"))
		}

		let strarray = pointer.pointee
		let references = strarray
			.filter {
				$0.hasPrefix(prefix)
			}
			.map {
				self.reference(named: $0)
			}
		git_strarray_free(pointer)
		pointer.deallocate()

		return references.aggregateResult()
	}

	/// Load the reference with the given long name (e.g. "refs/heads/master")
	///
	/// If the reference is a branch, a `Branch` will be returned. If the
	/// reference is a tag, a `TagReference` will be returned. Otherwise, a
	/// `Reference` will be returned.
	public func reference(named name: String) -> Result<ReferenceType, NSError> {
		var pointer: OpaquePointer? = nil
		let result = git_reference_lookup(&pointer, self.pointer, name)

		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_reference_lookup"))
		}

		let value = referenceWithLibGit2Reference(pointer!)
		git_reference_free(pointer)
		return Result.success(value)
	}

	/// Load and return a list of all local branches.
	public func localBranches() -> Result<[Branch], NSError> {
		return references(withPrefix: "refs/heads/")
			.map { (refs: [ReferenceType]) in
				return refs.map { $0 as! Branch }
			}
	}

	/// Load and return a list of all remote branches.
	public func remoteBranches() -> Result<[Branch], NSError> {
		return references(withPrefix: "refs/remotes/")
			.map { (refs: [ReferenceType]) in
				return refs.map { $0 as! Branch }
			}
	}

	/// Load the local branch with the given name (e.g., "master").
	public func localBranch(named name: String) -> Result<Branch, NSError> {
		return reference(named: "refs/heads/" + name).map { $0 as! Branch }
	}

	/// Load the remote branch with the given name (e.g., "origin/master").
	public func remoteBranch(named name: String) -> Result<Branch, NSError> {
		return reference(named: "refs/remotes/" + name).map { $0 as! Branch }
	}

	/// Load and return a list of all the `TagReference`s.
	public func allTags() -> Result<[TagReference], NSError> {
		return references(withPrefix: "refs/tags/")
			.map { (refs: [ReferenceType]) in
				return refs.map { $0 as! TagReference }
			}
	}

	/// Load the tag with the given name (e.g., "tag-2").
	public func tag(named name: String) -> Result<TagReference, NSError> {
		return reference(named: "refs/tags/" + name).map { $0 as! TagReference }
	}

	// MARK: - Working Directory

	/// Load the reference pointed at by HEAD.
	///
	/// When on a branch, this will return the current `Branch`.
	public func HEAD() -> Result<ReferenceType, NSError> {
		var pointer: OpaquePointer? = nil
		let result = git_repository_head(&pointer, self.pointer)
		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_repository_head"))
		}
		let value = referenceWithLibGit2Reference(pointer!)
		git_reference_free(pointer)
		return Result.success(value)
	}

	/// A textual diff (unified patch format -- the same text `git diff`
	/// itself prints) between HEAD and the working tree, going through
	/// the index the way `git diff HEAD` does: staged and unstaged
	/// changes both show up in one pass, which is "everything different
	/// since the last commit," the question worth asking before deciding
	/// whether to revert something.
	///
	/// :param: paths Optional exact repository-relative paths to scope
	///                the diff to (not wildmatch patterns -- see
	///                checkout(paths:)'s doc comment for why exact-match
	///                is the right default for a caller-supplied path).
	///                Empty means the whole repository.
	/// :returns: Returns a result with the patch text (empty string if
	///            nothing differs) or the error that occurred.
	public func diffHeadToWorkingDirectory(paths: [String] = []) -> Result<String, NSError> {
		var treeObject: OpaquePointer? = nil
		let revparseResult = "HEAD^{tree}".withCString { git_revparse_single(&treeObject, self.pointer, $0) }
		guard revparseResult == GIT_OK.rawValue, let treeObject else {
			return .failure(NSError(gitError: revparseResult, pointOfFailure: "git_revparse_single"))
		}
		defer { git_object_free(treeObject) }

		return withGitStrArray(paths) { strarray -> Result<String, NSError> in
			var options = git_diff_options()
			git_diff_options_init(&options, UInt32(GIT_DIFF_OPTIONS_VERSION))
			if !paths.isEmpty {
				options.pathspec = strarray
				options.flags |= GIT_DIFF_DISABLE_PATHSPEC_MATCH.rawValue
			}

			var diff: OpaquePointer? = nil
			let diffResult = git_diff_tree_to_workdir_with_index(&diff, self.pointer, treeObject, &options)
			guard diffResult == GIT_OK.rawValue, let diff else {
				return .failure(NSError(gitError: diffResult, pointOfFailure: "git_diff_tree_to_workdir_with_index"))
			}
			defer { git_diff_free(diff) }

			var buf = git_buf()
			let bufResult = git_diff_to_buf(&buf, diff, GIT_DIFF_FORMAT_PATCH)
			guard bufResult == GIT_OK.rawValue else {
				return .failure(NSError(gitError: bufResult, pointOfFailure: "git_diff_to_buf"))
			}
			defer { git_buf_dispose(&buf) }
			return .success(buf.ptr != nil ? String(cString: buf.ptr) : "")
		}
	}

	/// Set HEAD to the given oid (detached).
	///
	/// :param: oid The OID to set as HEAD.
	/// :returns: Returns a result with void or the error that occurred.
	public func setHEAD(_ oid: OID) -> Result<(), NSError> {
		var oid = oid.oid
		let result = git_repository_set_head_detached(self.pointer, &oid)
		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_repository_set_head"))
		}
		return Result.success(())
	}

	/// Set HEAD to the given reference.
	///
	/// :param: reference The reference to set as HEAD.
	/// :returns: Returns a result with void or the error that occurred.
	public func setHEAD(_ reference: ReferenceType) -> Result<(), NSError> {
		let result = git_repository_set_head(self.pointer, reference.longName)
		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_repository_set_head"))
		}
		return Result.success(())
	}

	/// Move a local branch's ref to point at a new target -- a fast-forward,
	/// e.g. after fetching -- without touching HEAD at all. If HEAD is
	/// already attached to this branch (the normal case: not detached, not
	/// on some other branch), HEAD "moves" along with it for free, since
	/// HEAD just points at the ref symbolically.
	///
	/// This is deliberately not `setHEAD(_ oid:)`: that calls
	/// `git_repository_set_head_detached`, which detaches HEAD from the
	/// branch entirely -- exactly wrong for a fast-forward pull, which
	/// should leave the user still "on" their branch, just further along
	/// it. Using `setHEAD(_ oid:)` for this (an earlier version of
	/// VaultLifecycle.pull did) left the repository in detached-HEAD state
	/// after every successful pull, which then broke every subsequent
	/// operation assuming an attached branch (push, another pull) with
	/// "HEAD is not on a branch (detached)".
	///
	/// :param: name   The local branch's short name (e.g. "main"), not the
	///                full "refs/heads/main" form.
	/// :param: target The commit to fast-forward the branch to.
	public func updateLocalBranch(named name: String, to target: OID) -> Result<(), NSError> {
		var oid = target.oid
		var ref: OpaquePointer? = nil
		let result = git_reference_create(&ref, self.pointer, "refs/heads/" + name, &oid, 1, "pull: Fast-forward")
		if let ref {
			git_reference_free(ref)
		}
		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_reference_create"))
		}
		return Result.success(())
	}

	/// Discard all uncommitted changes -- staged and unstaged -- and reset
	/// both the index and the working tree to exactly match `target`
	/// (`git reset --hard <target>`).
	///
	/// Deliberately not built out of `checkout(strategy: .Force)`: that
	/// only updates the working tree, and never touches the index at all
	/// -- a file staged with `git add` but never committed survives a
	/// plain forced checkout completely untouched, which isn't "discard
	/// everything," it's "discard everything except whatever happened to
	/// be staged." `git_reset(..., GIT_RESET_HARD, ...)` resets both in
	/// one call, which is what a host-app "revert to a known-good state"
	/// action actually needs to mean. Untracked/ignored files are left
	/// alone either way -- real `git reset --hard`'s own behavior, not
	/// `git clean`'s -- so this doesn't need `.RemoveUntracked` in its
	/// checkout strategy.
	///
	/// :param: target The commit to reset to -- typically the
	///                 repository's own current HEAD, for "throw away
	///                 everything since the last commit."
	/// :returns: Returns a result with void or the error that occurred.
	public func resetHard(to target: OID) -> Result<(), NSError> {
		return withGitObject(target, type: GIT_OBJECT_COMMIT) { commit in
			var options = checkoutOptions(strategy: .Force, progress: nil)
			let result = git_reset(self.pointer, commit, GIT_RESET_HARD, &options)
			guard result == GIT_OK.rawValue else {
				return Result.failure(NSError(gitError: result, pointOfFailure: "git_reset"))
			}
			return Result.success(())
		}
	}

	/// Check out HEAD.
	///
	/// :param: strategy The checkout strategy to use.
	/// :param: progress A block that's called with the progress of the checkout.
	/// :returns: Returns a result with void or the error that occurred.
	public func checkout(strategy: CheckoutStrategy, progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
		var options = checkoutOptions(strategy: strategy, progress: progress)

		let result = git_checkout_head(self.pointer, &options)
		guard result == GIT_OK.rawValue else {
			return Result.failure(NSError(gitError: result, pointOfFailure: "git_checkout_head"))
		}

		return Result.success(())
	}

	/// Check out HEAD for specific paths only (`git checkout HEAD --
	/// <paths>`) -- resets the index AND working tree for just those
	/// paths back to HEAD's content (git_checkout_head's own documented
	/// behavior: "Updates files in the index and the working tree to
	/// match the content of the commit pointed at by HEAD"), leaving
	/// every other path in the working tree completely untouched.
	///
	/// `.DisablePathspecMatch` is always added to `strategy` -- `paths`
	/// is exact filenames from a caller (e.g. a vault-relative path an
	/// agent is reverting), not wildmatch patterns, and a path that
	/// happens to contain a glob-special character (`[`, `*`, `?`)
	/// should still match itself literally rather than being
	/// reinterpreted as a pattern that could silently touch more files
	/// than asked.
	///
	/// :param: paths Exact repository-relative file paths to check out.
	/// :param: strategy The checkout strategy to use.
	/// :param: progress A block that's called with the progress of the checkout.
	/// :returns: Returns a result with void or the error that occurred.
	public func checkout(paths: [String], strategy: CheckoutStrategy = .Force,
	                     progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
		var options = checkoutOptions(strategy: strategy.union(.DisablePathspecMatch), progress: progress)
		return withGitStrArray(paths) { strarray in
			options.paths = strarray
			let result = git_checkout_head(self.pointer, &options)
			guard result == GIT_OK.rawValue else {
				return Result.failure(NSError(gitError: result, pointOfFailure: "git_checkout_head"))
			}
			return Result.success(())
		}
	}

	/// Check out the given OID.
	///
	/// :param: oid The OID of the commit to check out.
	/// :param: strategy The checkout strategy to use.
	/// :param: progress A block that's called with the progress of the checkout.
	/// :returns: Returns a result with void or the error that occurred.
	public func checkout(_ oid: OID, strategy: CheckoutStrategy,
	                     progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
		return setHEAD(oid).flatMap { self.checkout(strategy: strategy, progress: progress) }
	}

	/// Check out the given reference.
	///
	/// :param: reference The reference to check out.
	/// :param: strategy The checkout strategy to use.
	/// :param: progress A block that's called with the progress of the checkout.
	/// :returns: Returns a result with void or the error that occurred.
	public func checkout(_ reference: ReferenceType, strategy: CheckoutStrategy,
	                     progress: CheckoutProgressBlock? = nil) -> Result<(), NSError> {
		return setHEAD(reference).flatMap { self.checkout(strategy: strategy, progress: progress) }
	}

	/// Load all commits in the specified branch in topological & time order descending
	///
	/// :param: branch The branch to get all commits from
	/// :returns: Returns a result with array of branches or the error that occurred
	public func commits(in branch: Branch) -> CommitIterator {
		return commits(from: branch.oid)
	}

	/// Load all commits from the given base in topological & time order descending
	///
	/// :param: base The oid to get all commits from
	/// :returns: Returns a result with array of branches or the error that occurred
	public func commits(from base: OID) -> CommitIterator {
		let iterator = CommitIterator(repo: self, root: base.oid)
		return iterator
	}

	/// Get the index for the repo. The caller is responsible for freeing the index.
	func unsafeIndex() -> Result<OpaquePointer, NSError> {
		var index: OpaquePointer? = nil
		let result = git_repository_index(&index, self.pointer)
		guard result == GIT_OK.rawValue && index != nil else {
			let err = NSError(gitError: result, pointOfFailure: "git_repository_index")
			return .failure(err)
		}
		return .success(index!)
	}

	/// Stage the file(s) under the specified path.
	public func add(path: String) -> Result<(), NSError> {
		var dirPointer = UnsafeMutablePointer<Int8>(mutating: (path as NSString).utf8String)
		var paths = withUnsafeMutablePointer(to: &dirPointer) {
			git_strarray(strings: $0, count: 1)
		}
		return unsafeIndex().flatMap { index in
			defer { git_index_free(index) }
			let addResult = git_index_add_all(index, &paths, 0, nil, nil)
			guard addResult == GIT_OK.rawValue else {
				return .failure(NSError(gitError: addResult, pointOfFailure: "git_index_add_all"))
			}
			// write index to disk
			let writeResult = git_index_write(index)
			guard writeResult == GIT_OK.rawValue else {
				return .failure(NSError(gitError: writeResult, pointOfFailure: "git_index_write"))
			}
			return .success(())
		}
	}

	/// Perform a commit with arbitrary numbers of parent commits.
	public func commit(
		tree treeOID: OID,
		parents: [Commit],
		message: String,
		signature: Signature
	) -> Result<Commit, NSError> {
		// create commit signature
		return signature.makeUnsafeSignature().flatMap { signature in
			defer { git_signature_free(signature) }
			var tree: OpaquePointer? = nil
			var treeOIDCopy = treeOID.oid
			let lookupResult = git_tree_lookup(&tree, self.pointer, &treeOIDCopy)
			guard lookupResult == GIT_OK.rawValue else {
				let err = NSError(gitError: lookupResult, pointOfFailure: "git_tree_lookup")
				return .failure(err)
			}
			defer { git_tree_free(tree) }

			var msgBuf = git_buf()
			git_message_prettify(&msgBuf, message, 0, /* ascii for # */ 35)
			defer { git_buf_free(&msgBuf) }

			// libgit2 expects a C-like array of parent git_commit pointer
			var parentGitCommits: [OpaquePointer?] = []
			defer {
				for commit in parentGitCommits {
					git_commit_free(commit)
				}
			}
			for parentCommit in parents {
				var parent: OpaquePointer? = nil
				var oid = parentCommit.oid.oid
				let lookupResult = git_commit_lookup(&parent, self.pointer, &oid)
				guard lookupResult == GIT_OK.rawValue else {
					let err = NSError(gitError: lookupResult, pointOfFailure: "git_commit_lookup")
					return .failure(err)
				}
				parentGitCommits.append(parent!)
			}

			let parentsContiguous = ContiguousArray(parentGitCommits)
			return parentsContiguous.withUnsafeBufferPointer { unsafeBuffer in
				var commitOID = git_oid()
				let parentsPtr = UnsafeMutablePointer(mutating: unsafeBuffer.baseAddress)
				let result = git_commit_create(
					&commitOID,
					self.pointer,
					"HEAD",
					signature,
					signature,
					"UTF-8",
					msgBuf.ptr,
					tree,
					parents.count,
					parentsPtr
				)
				guard result == GIT_OK.rawValue else {
					return .failure(NSError(gitError: result, pointOfFailure: "git_commit_create"))
				}
				return commit(OID(commitOID))
			}
		}
	}

	/// Perform a commit of the staged files with the specified message and
	/// signature, creating the repository's first commit if HEAD is
	/// unborn (no commits yet) rather than requiring one to already exist.
	///
	/// Added for Hemlock (github.com/yhahn/SwiftGit2): the existing
	/// `commit(message:signature:)` looks up HEAD as the parent
	/// unconditionally, so it cannot create a fresh repository's first
	/// commit. `unsafeIndex()`/tree-writing are module-internal, so this
	/// has to live here rather than being composed from outside.
	public func commitStagedChanges(message: String, signature: Signature) -> Result<Commit, NSError> {
		if case .success = HEAD() {
			return commit(message: message, signature: signature)
		}
		return unsafeIndex().flatMap { index in
			defer { git_index_free(index) }
			var treeOID = git_oid()
			let treeResult = git_index_write_tree(&treeOID, index)
			guard treeResult == GIT_OK.rawValue else {
				return .failure(NSError(gitError: treeResult, pointOfFailure: "git_index_write_tree"))
			}
			return commit(tree: OID(treeOID), parents: [], message: message, signature: signature)
		}
	}

	/// Perform a commit of the staged files with the specified message and signature,
	/// assuming we are not doing a merge and using the current tip as the parent.
	public func commit(message: String, signature: Signature) -> Result<Commit, NSError> {
		return unsafeIndex().flatMap { index in
			defer { git_index_free(index) }
			var treeOID = git_oid()
			let treeResult = git_index_write_tree(&treeOID, index)
			guard treeResult == GIT_OK.rawValue else {
				let err = NSError(gitError: treeResult, pointOfFailure: "git_index_write_tree")
				return .failure(err)
			}
			var parentID = git_oid()
			let nameToIDResult = git_reference_name_to_id(&parentID, self.pointer, "HEAD")
			guard nameToIDResult == GIT_OK.rawValue else {
				return .failure(NSError(gitError: nameToIDResult, pointOfFailure: "git_reference_name_to_id"))
			}
			return commit(OID(parentID)).flatMap { parentCommit in
				commit(tree: OID(treeOID), parents: [parentCommit], message: message, signature: signature)
			}
		}
	}

	// MARK: - Diffs

	public func diff(for commit: Commit) -> Result<Diff, NSError> {
		guard !commit.parents.isEmpty else {
			// Initial commit in a repository
			return self.diff(from: nil, to: commit.oid)
		}

		var mergeDiff: OpaquePointer? = nil
		defer { git_object_free(mergeDiff) }
		for parent in commit.parents {
			let error = self.diff(from: parent.oid, to: commit.oid) {
				switch $0 {
				case .failure(let error):
					return error

				case .success(let newDiff):
					if mergeDiff == nil {
						mergeDiff = newDiff
					} else {
						let mergeResult = git_diff_merge(mergeDiff, newDiff)
						guard mergeResult == GIT_OK.rawValue else {
							return NSError(gitError: mergeResult, pointOfFailure: "git_diff_merge")
						}
					}
					return nil
				}
			}

			if error != nil {
				return Result<Diff, NSError>.failure(error!)
			}
		}

		return .success(Diff(mergeDiff!))
	}

	private func diff(from oldCommitOid: OID?, to newCommitOid: OID?, transform: (Result<OpaquePointer, NSError>) -> NSError?) -> NSError? {
		assert(oldCommitOid != nil || newCommitOid != nil, "It is an error to pass nil for both the oldOid and newOid")

		var oldTree: OpaquePointer? = nil
		defer { git_object_free(oldTree) }
		if let oid = oldCommitOid {
			switch unsafeTreeForCommitId(oid) {
			case .failure(let error):
				return transform(.failure(error))
			case .success(let value):
				oldTree = value
			}
		}

		var newTree: OpaquePointer? = nil
		defer { git_object_free(newTree) }
		if let oid = newCommitOid {
			switch unsafeTreeForCommitId(oid) {
			case .failure(let error):
				return transform(.failure(error))
			case .success(let value):
				newTree = value
			}
		}

		var diff: OpaquePointer? = nil
		let diffResult = git_diff_tree_to_tree(&diff,
		                                       self.pointer,
		                                       oldTree,
		                                       newTree,
		                                       nil)

		guard diffResult == GIT_OK.rawValue else {
			return transform(.failure(NSError(gitError: diffResult,
			                                  pointOfFailure: "git_diff_tree_to_tree")))
		}

		return transform(Result<OpaquePointer, NSError>.success(diff!))
	}

	/// Memory safe
	private func diff(from oldCommitOid: OID?, to newCommitOid: OID?) -> Result<Diff, NSError> {
		assert(oldCommitOid != nil || newCommitOid != nil, "It is an error to pass nil for both the oldOid and newOid")

		var oldTree: Tree? = nil
		if let oldCommitOid = oldCommitOid {
			switch safeTreeForCommitId(oldCommitOid) {
			case .failure(let error):
				return .failure(error)
			case .success(let value):
				oldTree = value
			}
		}

		var newTree: Tree? = nil
		if let newCommitOid = newCommitOid {
			switch safeTreeForCommitId(newCommitOid) {
			case .failure(let error):
				return .failure(error)
			case .success(let value):
				newTree = value
			}
		}

		if oldTree != nil && newTree != nil {
			return withGitObjects([oldTree!.oid, newTree!.oid], type: GIT_OBJECT_TREE) { objects in
				var diff: OpaquePointer? = nil
				let diffResult = git_diff_tree_to_tree(&diff,
				                                       self.pointer,
				                                       objects[0],
				                                       objects[1],
				                                       nil)
				return processTreeToTreeDiff(diffResult, diff: diff)
			}
		} else if let tree = oldTree {
			return withGitObject(tree.oid, type: GIT_OBJECT_TREE, transform: { tree in
				var diff: OpaquePointer? = nil
				let diffResult = git_diff_tree_to_tree(&diff,
				                                       self.pointer,
				                                       tree,
				                                       nil,
				                                       nil)
				return processTreeToTreeDiff(diffResult, diff: diff)
			})
		} else if let tree = newTree {
			return withGitObject(tree.oid, type: GIT_OBJECT_TREE, transform: { tree in
				var diff: OpaquePointer? = nil
				let diffResult = git_diff_tree_to_tree(&diff,
				                                       self.pointer,
				                                       nil,
				                                       tree,
				                                       nil)
				return processTreeToTreeDiff(diffResult, diff: diff)
			})
		}

		return .failure(NSError(gitError: -1, pointOfFailure: "diff(from: to:)"))
	}

	private func processTreeToTreeDiff(_ diffResult: Int32, diff: OpaquePointer?) -> Result<Diff, NSError> {
		guard diffResult == GIT_OK.rawValue else {
			return .failure(NSError(gitError: diffResult,
			                        pointOfFailure: "git_diff_tree_to_tree"))
		}

		let diffObj = Diff(diff!)
		git_diff_free(diff)
		return .success(diffObj)
	}

	private func processDiffDeltas(_ diffResult: OpaquePointer) -> Result<[Diff.Delta], NSError> {
		var returnDict = [Diff.Delta]()

		let count = git_diff_num_deltas(diffResult)

		for i in 0..<count {
			let delta = git_diff_get_delta(diffResult, i)
			let gitDiffDelta = Diff.Delta((delta?.pointee)!)

			returnDict.append(gitDiffDelta)
		}

		let result = Result<[Diff.Delta], NSError>.success(returnDict)
		return result
	}

	private func safeTreeForCommitId(_ oid: OID) -> Result<Tree, NSError> {
		return withGitObject(oid, type: GIT_OBJECT_COMMIT) { commit in
			let treeId = git_commit_tree_id(commit)
			return tree(OID(treeId!.pointee))
		}
	}

	/// Caller responsible to free returned tree with git_object_free
	private func unsafeTreeForCommitId(_ oid: OID) -> Result<OpaquePointer, NSError> {
		var commit: OpaquePointer? = nil
		var oid = oid.oid
		let commitResult = git_object_lookup(&commit, self.pointer, &oid, GIT_OBJECT_COMMIT)
		guard commitResult == GIT_OK.rawValue else {
			return .failure(NSError(gitError: commitResult, pointOfFailure: "git_object_lookup"))
		}

		var tree: OpaquePointer? = nil
		let treeId = git_commit_tree_id(commit)
		let treeResult = git_object_lookup(&tree, self.pointer, treeId, GIT_OBJECT_TREE)

		git_object_free(commit)

		guard treeResult == GIT_OK.rawValue else {
			return .failure(NSError(gitError: treeResult, pointOfFailure: "git_object_lookup"))
		}

		return Result<OpaquePointer, NSError>.success(tree!)
	}

	// MARK: - Status

	public func status(options: StatusOptions = [.includeUntracked]) -> Result<[StatusEntry], NSError> {
		var returnArray = [StatusEntry]()

		// Do this because GIT_STATUS_OPTIONS_INIT is unavailable in swift
		let pointer = UnsafeMutablePointer<git_status_options>.allocate(capacity: 1)
		let optionsResult = git_status_init_options(pointer, UInt32(GIT_STATUS_OPTIONS_VERSION))
		guard optionsResult == GIT_OK.rawValue else {
			return .failure(NSError(gitError: optionsResult, pointOfFailure: "git_status_init_options"))
		}
		var listOptions = pointer.move()
		listOptions.flags = options.rawValue
		pointer.deallocate()

		var unsafeStatus: OpaquePointer? = nil
		defer { git_status_list_free(unsafeStatus) }
		let statusResult = git_status_list_new(&unsafeStatus, self.pointer, &listOptions)
		guard statusResult == GIT_OK.rawValue, let unwrapStatusResult = unsafeStatus else {
			return .failure(NSError(gitError: statusResult, pointOfFailure: "git_status_list_new"))
		}

		let count = git_status_list_entrycount(unwrapStatusResult)

		for i in 0..<count {
			let s = git_status_byindex(unwrapStatusResult, i)
			if s?.pointee.status.rawValue == GIT_STATUS_CURRENT.rawValue {
				continue
			}

			let statusEntry = StatusEntry(from: s!.pointee)
			returnArray.append(statusEntry)
		}

		return .success(returnArray)
	}

	// MARK: - Validity/Existence Check

	/// - returns: `.success(true)` iff there is a git repository at `url`,
	///   `.success(false)` if there isn't,
	///   and a `.failure` if there's been an error.
	public static func isValid(url: URL) -> Result<Bool, NSError> {
		var pointer: OpaquePointer?

		let result = url.withUnsafeFileSystemRepresentation {
			git_repository_open_ext(&pointer, $0, GIT_REPOSITORY_OPEN_NO_SEARCH.rawValue, nil)
		}

		switch result {
		case GIT_ENOTFOUND.rawValue:
			return .success(false)
		case GIT_OK.rawValue:
			return .success(true)
		default:
			return .failure(NSError(gitError: result, pointOfFailure: "git_repository_open_ext"))
		}
	}
}

private extension Array {
	func aggregateResult<Value, Error>() -> Result<[Value], Error> where Element == Result<Value, Error> {
		var values: [Value] = []
		for result in self {
			switch result {
			case .success(let value):
				values.append(value)
			case .failure(let error):
				return .failure(error)
			}
		}
		return .success(values)
	}
}
