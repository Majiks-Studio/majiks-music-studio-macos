import Foundation

// MARK: - Capability merge (lane L4)
//
// gen.capabilities "merges: for each endpoint, which ops it supports"
// (P1-L4 brief, scope item 3). Pulled out as a PURE function so it is unit
// testable without a live Python backend or a live ServerPool (the brief
// asks for "a Swift unit test for capability merging").
//
// Division of authority:
// - local-mlx / gen-node / uc-cloud: the PYTHON backend is the source of
//   truth (it owns those executors + adapters); take its gen.capabilities
//   endpoints verbatim.
// - remote-ace: the SWIFT ServerPool is the source of truth (it owns the
//   configured servers, their Keychain keys, and their health checks). The
//   merge REPLACES whatever Python guessed for remote-ace with what
//   ServerPool actually knows: how many healthy servers, their slot
//   capacity, and their advertised models.
//
// Build-time verification of the route caveat (02-ARCH section 5, brief
// scope item 3 "VERIFY at build time whether the remote /api/v1/studio/*
// surface supports task_type beyond text2music; if not, capabilities marks
// revise-class ops local-only"):
//
//   The existing Swift remote path is RemoteGenerationService.submitJob ->
//   POST /api/v1/studio/generate with body {"params": RemoteGenerationParams
//   .toDictionary()}. RemoteGenerationParams has NO task_type, NO
//   src_audio_path, NO repainting_start/end, NO instruction field (read the
//   struct: it is tags/lyrics/duration/tempo/key/seed + LM/diffusion knobs,
//   i.e. text2music only). So this route is generate-only by construction.
//   That is why REMOTE_ACE_SUPPORTED_OPS below is exactly ["generate"], and
//   why revise/extend/layer/retake/autocomplete/cover/separate/analyze/
//   finalize are local-only on this route. P0-A separately proved the RAW
//   stock ACE api_server (/release_task) DOES carry those fields, but that
//   is the gen-node route's protocol, reached through Python's
//   _StockAceServerClient, not this /api/v1/studio bridge.

/// What the Swift ServerPool knows about the remote-ace route right now.
/// Kept as a plain value type so the merge is pure and testable.
struct RemoteAceAvailability: Sendable, Equatable {
    /// Total concurrent slots across healthy, enabled servers
    /// (sum of each server's maxConcurrentJobs).
    var concurrentSlots: Int
    /// Union of models advertised by the configured servers (from their
    /// /v1/models). Empty is fine (graceful unknown).
    var models: [String]

    static let none = RemoteAceAvailability(concurrentSlots: 0, models: [])
}

enum GenProtocolCapabilityMerge {
    /// Ops the existing Swift remote path (ServerPool + RemoteGeneration
    /// Service, POST /api/v1/studio/generate) can actually run. Text2music
    /// only, verified at build time by the shape of RemoteGenerationParams
    /// (see file header). Anything not in this set is local-only on
    /// remote-ace.
    static let remoteAceSupportedOps: [String] = [GenProtocolOp.generate.rawValue]

    static func merge(python: GenProtocolCapabilities, remoteAce: RemoteAceAvailability) -> GenProtocolCapabilities {
        var merged: [GenProtocolCapabilityEndpoint] = []
        var sawRemoteAce = false

        for endpoint in python.endpoints {
            if endpoint.route == .remoteAce {
                sawRemoteAce = true
                merged.append(remoteAceEndpoint(remoteAce))
            } else {
                // local-mlx / gen-node / uc-cloud: Python is authoritative.
                merged.append(endpoint)
            }
        }

        // If Python did not report remote-ace at all, still surface it from
        // Swift's own ServerPool truth so the UI/agents can see it.
        if !sawRemoteAce {
            merged.append(remoteAceEndpoint(remoteAce))
        }

        return GenProtocolCapabilities(endpoints: merged)
    }

    private static func remoteAceEndpoint(_ availability: RemoteAceAvailability) -> GenProtocolCapabilityEndpoint {
        // With no healthy servers there are zero slots; still advertise the
        // op set so a caller can see remote-ace exists but is currently
        // unavailable (concurrentSlots == 0), matching how the Python side
        // reports gen-node when unconfigured.
        GenProtocolCapabilityEndpoint(
            route: .remoteAce,
            ops: availability.concurrentSlots > 0 ? remoteAceSupportedOps : [],
            models: availability.models,
            concurrentSlots: availability.concurrentSlots
        )
    }

    /// Convenience for callers who have a raw endpoints array (e.g. from a
    /// decoded gen.capabilities) and just want to know if an op is runnable
    /// anywhere with capacity.
    static func isRunnable(_ op: GenProtocolOp, in capabilities: GenProtocolCapabilities) -> Bool {
        !capabilities.routes(supporting: op).isEmpty
    }
}
