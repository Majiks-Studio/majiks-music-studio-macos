//! The MCP tool registry, GENERATED from `command-catalog.v1.json`.
//!
//! One tool per catalog command (`studio_<name>`), its inputSchema taken
//! VERBATIM from the catalog `paramsSchema`, so the tool set can never drift
//! from the bus: adding a command adds a tool, changing a param changes the
//! schema, both for free. Plus the read tools, the gen proxy tools, and two
//! session tools (undo/redo). The parity gate test (`tests/parity.rs`) fails
//! the build if any catalog command lacks a tool and is not a documented
//! exclusion.
//!
//! Tier mapping (02-ARCH D4 + the L6 brief):
//! - reads            -> Read   (the dedicated read tools)
//! - mutations        -> Perform
//! - delete-class + export/publish -> Manage (require `confirm: true`)

use std::sync::OnceLock;

use serde::Serialize;
use serde_json::{json, Map, Value};

/// The one catalog command that gets NO tool: `gen.landed` is written by the
/// engine itself (`actor.kind = system`) when an async gen job completes; it
/// is not an agent-invocable command. Documented exclusion; the parity gate
/// allows exactly this.
pub const EXCLUDED_COMMANDS: &[&str] = &["gen.landed"];

/// Commands that delete user content or write/publish outside the project:
/// Manage tier, `confirm: true` required.
const MANAGE_COMMANDS: &[&str] = &[
    "track.remove",
    "clip.remove",
    "export.master",
    "export.stems",
    "export.region",
    "export.manifest",
    "publish.track",
    "take.purge",
    "midi.map.export",
];

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum ToolTier {
    Read,
    Perform,
    Manage,
}

impl ToolTier {
    pub fn as_str(self) -> &'static str {
        match self {
            ToolTier::Read => "read",
            ToolTier::Perform => "perform",
            ToolTier::Manage => "manage",
        }
    }
}

/// How the dispatcher routes a tool call.
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "snake_case")]
pub enum ToolKind {
    /// Route `catalog_name` through the command bus with the tool's params.
    Command,
    /// A read tool (host read surface), routed by tool `name`.
    Read,
    /// A gen proxy tool, routed to L4's gen protocol by tool `name`.
    Gen,
    /// A session op not in the catalog (undo/redo), routed by tool `name`.
    Session,
    /// The L8 landing bridge (build a stem session from a song, open it),
    /// routed by tool `name`.
    Landing,
    /// The L9 revise/extend/layer workflow tools (each is a whole pipeline of
    /// catalog commands: gen.revise/gen.landed/take.promote/...), routed by
    /// tool `name`. Agents get the killer feature with one call, over the SAME
    /// command bus a person uses.
    Revise,
    /// A host-io maintenance tool (L10 take purge): reclaims disk in the
    /// package, not a journaled timeline mutation. Routed by tool `name`.
    Maintenance,
}

#[derive(Debug, Clone, Serialize)]
pub struct ToolDef {
    pub name: String,
    pub tier: ToolTier,
    pub kind: ToolKind,
    /// The catalog command this tool submits (Command kind only).
    #[serde(skip_serializing_if = "Option::is_none")]
    pub catalog_name: Option<String>,
    /// Manage tools require `confirm: true`.
    pub confirm_required: bool,
    pub description: String,
    /// MCP inputSchema (catalog paramsSchema verbatim for Command tools).
    pub input_schema: Value,
}

/// One parsed catalog command (name + description + paramsSchema + flags).
struct CatalogCmd {
    name: String,
    description: String,
    params_schema: Value,
}

fn catalog_commands() -> &'static Vec<CatalogCmd> {
    static CMDS: OnceLock<Vec<CatalogCmd>> = OnceLock::new();
    CMDS.get_or_init(|| {
        let doc: Value = serde_json::from_str(timeline_core::catalog::CATALOG_JSON)
            .expect("embedded catalog must parse");
        doc.get("commands")
            .and_then(Value::as_array)
            .expect("catalog has a commands array")
            .iter()
            .map(|c| CatalogCmd {
                name: c["name"].as_str().unwrap_or_default().to_string(),
                description: c["description"].as_str().unwrap_or_default().to_string(),
                params_schema: c["paramsSchema"].clone(),
            })
            .collect()
    })
}

/// `project.setTempo` -> `studio_project_set_tempo` (camelCase + dots folded to
/// snake_case, MCP-safe [a-z0-9_] charset). Deterministic; the tool->command
/// mapping is carried by `catalog_name`, not by reversing this.
pub fn tool_name_for(catalog_name: &str) -> String {
    let mut out = String::from("studio_");
    let mut prev_word_char = false; // lower/digit before an uppercase = a hump
    for ch in catalog_name.chars() {
        if ch == '.' {
            out.push('_');
            prev_word_char = false;
        } else if ch.is_ascii_uppercase() {
            if prev_word_char {
                out.push('_');
            }
            out.push(ch.to_ascii_lowercase());
            prev_word_char = false;
        } else {
            out.push(ch);
            prev_word_char = ch.is_ascii_lowercase() || ch.is_ascii_digit();
        }
    }
    out
}

/// The tool inputSchema for a command tool: the catalog paramsSchema verbatim,
/// EXCEPT `import.audio`, whose tool is host-decomposed (io + `clip.place`) and
/// therefore also accepts optional placement hints `clipId` and `startTicks`
/// (documented deviation: the catalog `import.audio` params stay the core; the
/// host adds where-to-place). additionalProperties stays false.
fn command_input_schema(cmd: &CatalogCmd) -> Value {
    if cmd.name != "import.audio" {
        return cmd.params_schema.clone();
    }
    let mut obj = cmd.params_schema.as_object().cloned().unwrap_or_default();
    let mut props = obj
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    props.insert(
        "clipId".into(),
        json!({ "type": "string", "minLength": 1, "description": "Placement hint: id for the placed clip (minted if omitted)." }),
    );
    props.insert(
        "startTicks".into(),
        json!({ "type": "integer", "minimum": 0, "description": "Placement hint: clip start on the target track (default 0)." }),
    );
    // ...and it re-describes two flags the CATALOG declares and the host does
    // not implement. `separate` and `conform` are read nowhere in
    // `import_audio_params`: passing either returns ok and lands one ordinary
    // clip. The catalog text cannot be corrected here (it is frozen contract law
    // and its wording is what a v1.1 project replays against), and the schema
    // cannot REFUSE them without narrowing a journaled command, which would
    // break reopening any project that ever passed one. What it can do is stop a
    // caller reading the promise in the first place, and name the tool that
    // actually does the job. The result JSON says the same thing again at call
    // time (`ignoredParams`), because a schema is read once and a result every
    // time.
    for (key, note) in [
        (
            "separate",
            "NOT IMPLEMENTED and silently ignored — this imports one ordinary clip. For stem separation use studio_open_in_studio, or import.stems with stems you separated yourself.",
        ),
        (
            "conform",
            "NOT IMPLEMENTED and silently ignored — the audio is imported at its own length. To fit it to the project tempo, place it and then call clip.warp.set with mode 'conform'.",
        ),
    ] {
        // The description ONLY. A JSON Schema `deprecated: true` would say this
        // more formally and `schema::validate` refuses it — the validator
        // enforces a closed keyword subset, so an unsupported annotation makes
        // every call to this tool fail validation rather than being ignored.
        // That is the right behaviour and it is why this is prose.
        if let Some(Value::Object(p)) = props.get_mut(key) {
            p.insert("description".into(), json!(note));
        }
    }
    obj.insert("properties".into(), Value::Object(props));
    Value::Object(obj)
}

fn tier_for(catalog_name: &str) -> (ToolTier, bool) {
    if MANAGE_COMMANDS.contains(&catalog_name) {
        (ToolTier::Manage, true)
    } else {
        (ToolTier::Perform, false)
    }
}

/// Add a required `confirm: true` gate to a catalog schema (Manage tools).
/// The bus never sees `confirm`; the dispatcher strips it after checking.
fn with_confirm(schema: &Value) -> Value {
    let mut obj = schema.as_object().cloned().unwrap_or_default();
    let mut props = obj
        .get("properties")
        .and_then(Value::as_object)
        .cloned()
        .unwrap_or_default();
    props.insert(
        "confirm".into(),
        json!({
            "type": "boolean",
            "const": true,
            "description": "Must be true. This tool deletes project content or writes/publishes outside the project."
        }),
    );
    obj.insert("properties".into(), Value::Object(props));
    let mut required = obj
        .get("required")
        .and_then(Value::as_array)
        .cloned()
        .unwrap_or_default();
    if !required.iter().any(|v| v.as_str() == Some("confirm")) {
        required.push(json!("confirm"));
    }
    obj.insert("required".into(), Value::Array(required));
    Value::Object(obj)
}

fn obj_schema(props: Value, required: &[&str]) -> Value {
    json!({
        "type": "object",
        "properties": props,
        "required": required,
        "additionalProperties": false,
    })
}

/// The full generated tool set: command tools (from the catalog) + read tools
/// + gen proxy tools + session tools.
pub fn tool_defs() -> Vec<ToolDef> {
    let mut defs = Vec::new();

    // 1. One tool per catalog command (minus documented exclusions).
    for cmd in catalog_commands() {
        if EXCLUDED_COMMANDS.contains(&cmd.name.as_str()) {
            continue;
        }
        let (tier, confirm) = tier_for(&cmd.name);
        let base_schema = command_input_schema(cmd);
        let input_schema = if confirm {
            with_confirm(&base_schema)
        } else {
            base_schema
        };
        defs.push(ToolDef {
            name: tool_name_for(&cmd.name),
            tier,
            kind: ToolKind::Command,
            catalog_name: Some(cmd.name.clone()),
            confirm_required: confirm,
            description: cmd.description.clone(),
            input_schema,
        });
    }

    // 2. Read tools (host read surface; never mutate).
    defs.push(read_tool(
        "studio_snapshot",
        "Full current project state, or a change delta when sinceSeq is given (diff-cursor).",
        obj_schema(
            json!({ "sinceSeq": { "type": "integer", "minimum": 0, "description": "Diff cursor: pass the `seq` from a previous answer to get only what changed since then. The reply is either { unchanged: true }, a { scopes: [...] } delta, or { resync: true } when too much has changed to describe incrementally. Omit for the whole project." } }),
            &[],
        ),
    ));
    defs.push(read_tool(
        "studio_journal",
        "A page of hash-chained journal (provenance) entries after afterId.",
        obj_schema(
            json!({
                "afterId": { "type": "string", "description": "Page cursor: the `id` of the last entry you already have. Entries AFTER it are returned, exclusive. Omit to start at the beginning of the journal." },
                "limit": { "type": "integer", "minimum": 1, "maximum": 500, "description": "Entries per page, default 100, capped at 500." }
            }),
            &[],
        ),
    ));
    defs.push(read_tool(
        "studio_engine_stats",
        "Render engine health: underruns and callback p95 (offline surface reports a clean baseline until live playback lands at I1).",
        obj_schema(json!({}), &[]),
    ));
    // WHAT THE FADERS ARE DOING TO THE SIGNAL. The host has computed these
    // since I1 and the Swift app reads them over `ffi_studio_meters`; there was
    // simply no tool, so levels were a thing only the human half of the app
    // could see. Meters are the answer to "did that work" for the whole mixer
    // and for picking which mic is on which input, and neither question is
    // answerable from the project model.
    defs.push(read_tool(
        "studio_meters",
        "Current levels: per-track, per-bus/group node, master (with true peak, LUFS, limiter gain reduction and stereo correlation), and — when an input is open — per-channel input peak/RMS with a latched clip flag. Use the input channels to tell which mic is on which input before a take. Says live:false and reports an honest -120 dB silence floor when no live audio session is running; the input meter is present whenever record.inputListen or record.start has opened the input, live session or not.",
        obj_schema(json!({}), &[]),
    ));
    // THE VOCABULARIES. Read-only, static, and answerable before a project is
    // open — see `capabilities.rs` for why each list is here rather than in
    // this repository only.
    defs.push(read_tool(
        "studio_capabilities",
        "The closed vocabularies you have to choose from: instrument kinds and their parameter keys, the named instrument PRESETS a person clicks (id, name, plain-language blurb, and the exact device.param.set values each one is), effect kinds and their parameter keys, the node-ref and ParamRef grammars for addressing fx hosts and automation lanes, export formats and loudness targets, and the stem separators. Call this before naming a parameter key, an effect kind, or a sound: device.param.set and fx.param.set REFUSE a key outside these lists.",
        obj_schema(json!({}), &[]),
    ));
    // The manifest as a READ. `export.manifest` is Manage tier because it
    // writes a file outside the project; asking what that file would say is not
    // a destructive act and must not require claiming it is one, nor a
    // round-trip through the filesystem an MCP client may not even share.
    defs.push(read_tool(
        "studio_manifest",
        "The full provenance / AI-disclosure manifest for the CURRENT project state, without writing a file: the generated/imported/recorded/authored split by clip count and by duration, per-clip lineage and IPTC DigitalSourceType, the models used, and the blake3 hash-chain head. Identical content to what export.manifest would write. Use export.manifest when you need the artifact on disk; use this to read it.",
        obj_schema(json!({}), &[]),
    ));
    defs.push(read_tool(
        "studio_waveform",
        "Capped peak-tile array for a clip's window at a zoom bucket. Never returns raw audio.",
        obj_schema(
            json!({
                "clipId": { "type": "string", "minLength": 1, "description": "The clip whose audio to summarise. A note-backed (MIDI) clip and a clip whose asset is offline both answer with an empty peak array rather than an error." },
                "zoom": { "type": "integer", "minimum": 0, "maximum": 16, "description": "Zoom bucket. Each bin covers 256 << zoom samples, so 0 is the finest detail and 16 the coarsest overview. The answer restates the resolved samplesPerBin." },
                "startBin": { "type": "integer", "minimum": 0, "description": "First bin to return, for paging a long clip. Default 0." },
                "maxBins": { "type": "integer", "minimum": 1, "maximum": 2048, "description": "How many bins to return, capped at 2048. The answer carries totalBins so you can tell whether you have the whole clip." }
            }),
            &["clipId"],
        ),
    ));
    defs.push(read_tool(
        "studio_takes",
        "Generative takes for the Takes browser, each with its kind + joined lineage (prompt/seed/model/engine/region). Filters: clipId, requestId, kind, auditionableOnly (drops landing provenance + finalize + offline), includePurged. A landed song's gen.song take is kind 'landing' (provenance, not an alternative).",
        obj_schema(
            json!({
                "clipId": { "type": "string", "minLength": 1, "description": "Only takes promoted into this clip." },
                "requestId": { "type": "string", "minLength": 1, "description": "Only takes from this gen request." },
                "kind": { "type": "string", "enum": ["revise", "extend", "layer", "retake", "landing", "finalize", "cover", "autocomplete", "other"], "description": "Only takes of this kind." },
                "auditionableOnly": { "type": "boolean", "description": "Only live candidate ALTERNATIVES (drops landing provenance, finalize intermediates, and offline takes)." },
                "includePurged": { "type": "boolean", "description": "Include offline (purged / missing-asset) takes. Default true." }
            }),
            &[],
        ),
    ));
    defs.push(read_tool(
        "studio_lineage",
        "Per-clip provenance chain: the journal entries that produced this clip's current audio.",
        obj_schema(
            json!({ "clipId": { "type": "string", "minLength": 1, "description": "The clip to trace. Refuses with code `unknown_clip` if it does not exist." } }),
            &["clipId"],
        ),
    ));
    // Take maintenance (L10): reclaim disk by purging candidate take audio.
    // Host-io, not a catalog command; carries its own confirm gate (destructive).
    defs.push(ToolDef {
        name: "studio_purge_takes".into(),
        tier: ToolTier::Manage,
        kind: ToolKind::Maintenance,
        catalog_name: None,
        confirm_required: true,
        description: "Reclaim disk by deleting the audio of purgeable CANDIDATE takes (never a placed clip, a promoted take's un-splice, or a landing anchor). The take records stay queryable as lineage and read back offline. Requires confirm: true.".into(),
        input_schema: obj_schema(
            json!({
                "confirm": { "type": "boolean", "description": "Must be true (destructive: deletes take audio)." },
                "takeId": { "type": "string", "minLength": 1, "description": "Purge only this take (default: all purgeable candidates)." },
                "requestId": { "type": "string", "minLength": 1, "description": "Purge only this request's candidate takes." }
            }),
            &["confirm"],
        ),
    });

    // 3. Gen proxy tools (forward to L4's gen protocol; proxy only).
    let gen_op = json!({
        "type": "string",
        "enum": ["generate","revise","extend","layer","retake","separate","analyze","autocomplete","cover"],
        "description": "Which Gen Protocol operation to run: 'generate' (a new song from a caption), 'revise' (repaint a region), 'extend' (continue past the end), 'layer' (a new stem that fits context), 'retake' (same prompt, fresh seed), 'separate' (split into stems), 'analyze' (tempo/key/sections), 'autocomplete' (fill instruments in) or 'cover' (style transfer)."
    });
    defs.push(gen_tool(
        "gen_submit",
        "Submit a generation job to the Gen Protocol service (L4). Returns a jobId; poll gen_status.",
        obj_schema(
            json!({
                "op": gen_op,
                "request": { "type": "object", "description": "The Gen Protocol request body for this op, forwarded verbatim. Its shape is the op's own (gen-protocol.v1.yaml); this proxy validates nothing beyond it being an object." }
            }),
            &["op", "request"],
        ),
    ));
    defs.push(gen_tool(
        "gen_status",
        "Poll a gen job's progress/terminal state by jobId.",
        obj_schema(
            json!({ "jobId": { "type": "string", "minLength": 1, "description": "The job id gen_submit returned. Non-empty; minted by the Gen Protocol service, not by this engine." } }),
            &["jobId"],
        ),
    ));
    defs.push(gen_tool(
        "gen_cancel",
        "Cancel an in-flight gen job by jobId.",
        obj_schema(
            json!({ "jobId": { "type": "string", "minLength": 1, "description": "The job id gen_submit returned. Non-empty; minted by the Gen Protocol service, not by this engine." } }),
            &["jobId"],
        ),
    ));
    defs.push(gen_tool(
        "gen_capabilities",
        "Per-endpoint supported gen ops, models, and concurrent slots (ServerPool merge).",
        obj_schema(json!({}), &[]),
    ));

    // 3b. The landing bridge (L8): a song -> a bar-aligned stem session, opened.
    // Not a catalog command (it is a whole pipeline of them); a Perform-tier
    // tool so an agent can "open this song in the studio" with one call.
    defs.push(ToolDef {
        name: "studio_open_in_studio".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Landing,
        catalog_name: None,
        confirm_required: false,
        description: "Open a finished song in the Studio: beat-tracked tempo + downbeats, stem separation, bar-aligned stem tracks with lineage, section map. Builds a new .mstudio and makes it the active project.".into(),
        input_schema: obj_schema(
            json!({
                "sourceAudioRef": { "type": "string", "minLength": 1, "description": "Path to the finished-song mix WAV." },
                "prompt": { "type": "string", "description": "The generation prompt (recorded on every clip's lineage)." },
                "declaredBpm": { "type": "number", "exclusiveMinimum": 0, "description": "Tag/declared BPM, used only as a tie-break hint (never the grid; measured BPM wins)." },
                "key": { "type": "string", "description": "Declared key, e.g. 'A minor'. Falls back to the measured key." },
                "sectionTags": { "type": "array", "items": { "type": "string" }, "description": "Ordered section names from the lyrics ([verse]/[chorus]/...)." },
                "sectionTimes": { "type": "array", "items": { "type": "number" }, "description": "Optional per-tag start times (seconds); each snaps to the nearest downbeat." },
                "seed": { "type": "integer", "description": "Generation seed (lineage)." },
                "genModel": { "type": "string", "description": "Generation model, e.g. acestep-v15-turbo (lineage)." },
                "genDevice": { "type": "string", "enum": ["mlx", "mps", "cuda", "cpu", "remote"], "description": "Generation device (lineage)." },
                "source": { "type": "string", "enum": ["generated", "library", "imported"], "description": "Where the song came from." },
                "projectName": { "type": "string", "description": "Project display name (default: the mix file stem)." },
                "separator": { "type": "string", "enum": ["htdemucs", "provided"], "description": "Stem source; default htdemucs. htdemucs is the shipped separator (demucs 4-stem, via the bundled Python runtime); provided uses four stem files you separated yourself. Both must produce stems that are usable ALONE. The interleave test fixture is deliberately NOT offered here: its stems sum back to the mix but each one is 75% silence and screeches when soloed." },
                "stems": {
                    "type": "object",
                    "description": "Pre-separated stem paths (separator=provided).",
                    "properties": {
                        "vocals": { "type": "string", "description": "Path to the vocals stem file. Required when separator is 'provided'." },
                        "drums": { "type": "string", "description": "Path to the drums stem file. Required when separator is 'provided'." },
                        "bass": { "type": "string", "description": "Path to the bass stem file. Required when separator is 'provided'." },
                        "other": { "type": "string", "description": "Path to the 'other' stem file (everything not vocals/drums/bass). Required when separator is 'provided'." }
                    },
                    "required": ["vocals", "drums", "bass", "other"],
                    "additionalProperties": false
                },
                "separatorModel": { "type": "string", "description": "Model name to record when separator=provided (default htdemucs)." },
                "pythonSrc": { "type": "string", "description": "Directory holding majik_backend (separator=htdemucs). Optional: discovered from the app bundle, MAJIKS_PYTHON_SRC, or a dev checkout when omitted. Naming a path with no majik_backend in it is an error, not a fall-back." },
                "outputDir": { "type": "string", "description": "Directory to create the .mstudio in (default: the engine data dir)." }
            }),
            &["sourceAudioRef"],
        ),
    });

    // 3c. The revise/extend/layer workflow (L9): the killer feature. Each tool
    // is a whole pipeline of catalog commands (gen.revise + gen.landed + the
    // take.promote commit txn, etc.), so an agent gets "select bars, describe a
    // change, get variants, commit one" with one call, over the same bus + undo
    // a person uses. The timeline-commit side (take.promote / take.discard) also
    // exists as plain catalog command tools, so an agent can drive it either way.
    let engine_prop = json!({ "type": "string", "enum": ["mock", "live", "gen-node"], "description": "mock (deterministic fixture, default) or live (needs a Gen Node)." });
    let region_props = json!({
        "regionStartTicks": { "type": "integer", "minimum": 0, "description": "Region start in project ticks, on the bar-snapped beat-tracked grid (read ppq and tempoMap from studio_snapshot to convert bars to ticks; the grid origin is phaseAnchorTicks, which is not always 0)." },
        "regionEndTicks": { "type": "integer", "minimum": 1, "description": "Region end in project ticks, exclusive. Must be greater than regionStartTicks." },
    });
    defs.push(revise_tool(
        "studio_revise",
        ToolTier::Perform,
        "Revise a bar region: generate N draft variants for each scoped stem, splice each into the original clip audio with an equal-power crossfade inside the region (raw repaint never appears outside it, per P0-A), and land them as candidate takes. Returns the per-variant promotions to commit with studio_commit. Non-blocking.",
        obj_schema(
            json!({
                "clipId": { "type": "string", "minLength": 1, "description": "The clip to revise (all-stems, or a single-stem scope)." },
                "clipIds": { "type": "array", "items": { "type": "string", "minLength": 1 }, "description": "One stem clip per scoped stem, in scope order (stem-scope revise)." },
                "regionStartTicks": { "type": "integer", "minimum": 0, "description": "Region start in project ticks, on the bar-snapped beat-tracked grid. Read ppq and phaseAnchorTicks from studio_snapshot to convert bars to ticks — the grid origin is not always 0." },
                "regionEndTicks": { "type": "integer", "minimum": 1, "description": "Region end in project ticks, exclusive. Must be greater than regionStartTicks." },
                "scope": { "description": "'all-stems' (a single full-mix clip), a stem name, or an array of stem names (multi-select). Unscoped stems are null-preserved." },
                "instruction": { "type": "string", "description": "What should change, e.g. 'strip the drums to half-time, darker pads'." },
                "variants": { "type": "integer", "minimum": 1, "maximum": 8, "description": "Default 3 (seed variance dominates; takes are cheap)." },
                "seed": { "type": "integer", "minimum": 0, "description": "Base seed (advanced)." },
                "crossfadeMs": { "type": "number", "minimum": 5, "description": "Splice crossfade length, default 20 ms, 5 ms declick floor." },
                "rung": { "type": "string", "enum": ["draft", "standard", "full"], "description": "Audition rung; default draft (turbo-8). Commit finalizes at full." },
                "keepLyrics": { "type": "boolean", "description": "Resend the lyrics when vocals are in scope (the only honest toggle)." },
                "engine": engine_prop.clone()
            }),
            &["regionStartTicks", "regionEndTicks", "scope"],
        ),
    ));
    defs.push(revise_tool(
        "studio_audition",
        ToolTier::Read,
        "The audition loop for a revise region: the region with 2 bars of pre-roll. Switching which take is audible (keys 1-9, A for original, per-stem mixing) is a live-transport concern the app drives.",
        obj_schema(region_props.clone(), &["regionStartTicks", "regionEndTicks"]),
    ));
    defs.push(revise_tool(
        "studio_commit",
        ToolTier::Perform,
        "Commit a chosen variant: promote its take(s) into their clip(s) as ONE undo transaction, the crossfade already baked into each spliced asset. Pass the variant's promotions from studio_revise.",
        obj_schema(
            json!({
                "promotions": {
                    "type": "array",
                    "items": {
                        "type": "object",
                        "properties": {
                            "takeId": { "type": "string", "minLength": 1, "description": "The candidate take to promote, as studio_revise reported it in variantTakes." },
                            "clipId": { "type": "string", "minLength": 1, "description": "The clip that take is spliced into — one entry per scoped stem clip." }
                        },
                        "required": ["takeId", "clipId"],
                        "additionalProperties": true
                    },
                    "description": "The chosen variant's promotions (from studio_revise variantTakes)."
                },
                "reason": { "type": "string", "description": "Undo label, e.g. 'revise bars 33-48'." }
            }),
            &["promotions"],
        ),
    ));
    defs.push(revise_tool(
        "studio_finalize",
        ToolTier::Perform,
        "The draft/commit two-phase: re-render committed draft take(s) at the commit rung (base-50) and swap each clip's asset draft->full as ONE undo transaction. Reconstructs region + crossfade from journaled provenance, so it needs only the draft take ids. Sample-aligned and undoable.",
        obj_schema(
            json!({
                "draftTakeIds": { "type": "array", "items": { "type": "string", "minLength": 1 }, "description": "The committed draft takes to finalize." },
                "rung": { "type": "string", "enum": ["draft", "standard", "full"], "description": "Target rung, default full." },
                "engine": engine_prop.clone()
            }),
            &["draftTakeIds"],
        ),
    ));
    defs.push(revise_tool(
        "studio_discard",
        ToolTier::Perform,
        "Discard an audition without committing: the takes stay as candidates in the Takes history (purging them is the Takes browser's job).",
        obj_schema(
            json!({ "takeIds": { "type": "array", "items": { "type": "string", "minLength": 1 }, "description": "Optional take ids from the audition being abandoned; they are echoed back as kept. Omitted discards nothing and simply reports an empty set — the takes survive either way, because nothing was committed." } }),
            &[],
        ),
    ));
    defs.push(revise_tool(
        "studio_extend",
        ToolTier::Perform,
        "Extend a clip past its end (01-DESIGN 3.3): generate variant tails as candidate takes. Commit the chosen tail with studio_commit_extend (crossfaded at the seam, new section).",
        obj_schema(
            json!({
                "clipId": { "type": "string", "minLength": 1, "description": "The clip to extend past its end; the new audio is butt-joined at its tail." },
                "addedDurationSeconds": { "type": "number", "exclusiveMinimum": 0, "description": "Seconds of audio to add." },
                "instruction": { "type": "string", "description": "Optional, e.g. '16-bar outro, decays to vinyl noise'." },
                "variants": { "type": "integer", "minimum": 1, "maximum": 8, "description": "How many alternative tails to generate, 1 to 8. Default 1." },
                "seed": { "type": "integer", "minimum": 0, "description": "Optional base seed; each variant derives its own from it. Omitted uses a fixed built-in base, so a repeat call reproduces the same tails." },
                "crossfadeMs": { "type": "number", "minimum": 5, "description": "Optional seam crossfade length in milliseconds, 5 ms declick floor. Default 20 ms." },
                "engine": engine_prop.clone()
            }),
            &["clipId", "addedDurationSeconds"],
        ),
    ));
    defs.push(revise_tool(
        "studio_commit_extend",
        ToolTier::Perform,
        "Place a chosen extend tail as a new clip butt-joined at the seam, crossfade the seam, and add a section, as ONE undo transaction.",
        obj_schema(
            json!({
                "takeId": { "type": "string", "minLength": 1, "description": "The chosen tail take from studio_extend." },
                "clipId": { "type": "string", "minLength": 1, "description": "The clip being extended (the seam anchor)." },
                "crossfadeMs": { "type": "number", "minimum": 5, "description": "Optional seam crossfade length in milliseconds, 5 ms declick floor. Default 20 ms." },
                "sectionName": { "type": "string", "description": "Optional label for the arrangement section the tail becomes. Default 'Extension'." }
            }),
            &["takeId", "clipId"],
        ),
    ));
    defs.push(revise_tool(
        "studio_layer",
        ToolTier::Perform,
        "Add a Layer (01-DESIGN 3.3b, lego): generate a new instrument that fits a context region, as candidate takes. Commit with studio_commit_layer to land it on a NEW track.",
        obj_schema(
            json!({
                "instruction": { "type": "string", "minLength": 1, "description": "The instrument, e.g. 'warm analog bass', 'sax lead answering the vocal'." },
                "regionStartTicks": { "type": "integer", "minimum": 0, "description": "Start of the context region the layer has to fit, in project ticks. Read ppq and phaseAnchorTicks from studio_snapshot to convert bars to ticks." },
                "regionEndTicks": { "type": "integer", "minimum": 1, "description": "End of the context region in project ticks, exclusive. Must be greater than regionStartTicks." },
                "contextClipId": { "type": "string", "minLength": 1, "description": "Optional context clip the layer should fit." },
                "stem": { "type": "string", "enum": ["vocals", "drums", "bass", "other"], "description": "The stem lane the layer reads as (default other)." },
                "variants": { "type": "integer", "minimum": 1, "maximum": 8, "description": "How many alternative layers to generate, 1 to 8. Default 1." },
                "seed": { "type": "integer", "minimum": 0, "description": "Optional base seed; each variant derives its own from it. Omitted uses a fixed built-in base, so a repeat call reproduces the same layers." },
                "targetTrackId": { "type": "string", "minLength": 1, "description": "Optional id for the NEW track the layer lands on; it is created by this call. Omitted mints one ('trk_layer_<ulid>')." },
                "engine": engine_prop.clone()
            }),
            &["instruction", "regionStartTicks", "regionEndTicks"],
        ),
    ));
    defs.push(revise_tool(
        "studio_commit_layer",
        ToolTier::Perform,
        "Create a new track and place a chosen layer take on it at the region, as ONE undo transaction.",
        obj_schema(
            json!({
                "takeId": { "type": "string", "minLength": 1, "description": "The chosen layer take from studio_layer." },
                "regionStartTicks": { "type": "integer", "minimum": 0, "description": "Where the layer clip is placed, in project ticks — normally the same region start studio_layer was given." },
                "trackName": { "type": "string", "description": "Optional display name for the new track. Default 'Layer'." },
                "targetTrackId": { "type": "string", "minLength": 1, "description": "Optional id of the track studio_layer already created. Omitted mints a new one." },
                "color": { "type": "string", "pattern": "^#[0-9A-Fa-f]{6}$", "description": "Optional track colour as '#RRGGBB' hex. Omitted uses the stem's standard colour." }
            }),
            &["takeId", "regionStartTicks"],
        ),
    ));

    // 4. Session tools (not catalog commands; undo/redo the journaled history).
    defs.push(ToolDef {
        name: "studio_undo".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Session,
        catalog_name: None,
        confirm_required: false,
        description: "Undo the most recent undo unit (journaled forward; history never rewrites)."
            .into(),
        input_schema: obj_schema(json!({}), &[]),
    });
    defs.push(ToolDef {
        name: "studio_redo".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Session,
        catalog_name: None,
        confirm_required: false,
        description: "Redo the most recently undone unit.".into(),
        input_schema: obj_schema(json!({}), &[]),
    });
    // THE METRONOME's monitor state. A session tool and NOT a catalog command,
    // for the same reason `studio_note_preview` isn't one: hearing the grid
    // changes nothing. It is not journaled, not undoable, not replayed, and
    // not part of the project — a bounce of the same journal is bit-identical
    // whether this was on or off, because the click only exists on a core
    // that is driving a real output device (`render::rt::CoreConfig::monitor`).
    //
    // `transport.metronome` (catalog) remains the enable verb agents and MIDI
    // bindings already use; this tool adds the things that would otherwise
    // have needed an optional param bolted onto a v1.1 command, which E0 §9.2
    // forbids.
    defs.push(ToolDef {
        name: "studio_metronome_set".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Session,
        catalog_name: None,
        confirm_required: false,
        description: "Set the metronome's monitor state: turn the click on or off, set how loud it is, and start an audible count-in. The click is a synthesised transient on every beat, accented on the downbeat, locked to the project tempo map and phase anchor. It is MONITOR-ONLY: you hear it while you play, and it can never appear in an exported mix or in a recorded take. Nothing here is journaled or undoable."
            .into(),
        input_schema: obj_schema(
            json!({
                "enabled": { "type": "boolean", "description": "Turn the click on or off. Same state as transport.metronome." },
                "levelDb": { "type": "number", "minimum": -40, "maximum": 6, "description": "Click level relative to the default, in dB. 0 is the default level (-12 dBFS peak)." },
                "countInBeats": { "type": "integer", "minimum": 0, "maximum": 16, "description": "Sound this many count-in clicks starting NOW, accented on the first, whether or not the transport is rolling. 0 cancels a count-in in progress." }
            }),
            &[],
        ),
    });

    // AUDITION a note. A session tool and NOT a catalog command on purpose:
    // hearing a pitch changes nothing, so it must not be journaled, undoable, or
    // replayed. See StudioHost::preview_note for the audio-safety reasoning.
    defs.push(ToolDef {
        name: "studio_note_preview".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Session,
        catalog_name: None,
        confirm_required: false,
        description: "Sound one note on a track's instrument RIGHT NOW, outside the timeline (a piano-roll key, an on-screen key, a MIDI key). The note itself is not journaled and not undoable: this is feedback, not an edit. Omit trackId to play the project's instrument, creating one if the project has none (that creation IS journaled, as one undo step). Opens the output device only on a host whose GUI opted into audible output; on a headless host or under test it returns audible:false with a reason and makes no sound."
            .into(),
        input_schema: obj_schema(
            json!({
                "trackId": { "type": "string", "minLength": 1, "description": "The instrument track to sound. Omit to use the armed instrument track, else the first, else a newly created one." },
                "pitch": { "type": "integer", "minimum": 0, "maximum": 127, "description": "MIDI note number, 0 to 127; 60 is middle C." },
                "velocity": { "type": "integer", "minimum": 0, "maximum": 127, "description": "How hard the key is struck, 0 to 127. Optional, default 100." },
                "gate": { "type": "string", "enum": ["oneShot", "on", "off"], "description": "oneShot (default) releases itself after holdMs; on holds until a matching off (a held key)." },
                "holdMs": { "type": "integer", "minimum": 1, "maximum": 5000, "description": "One-shot length, default 350 ms." }
            }),
            &["pitch"],
        ),
    });

    // KEEP what was just played. Not a catalog command either: it is a
    // *reader* of the retro-capture buffer that then submits ordinary journaled
    // commands (clip.placeMidi + note.add inside a txn). The buffer itself is
    // ephemeral session state, so there is nothing here for replay to rebuild.
    defs.push(ToolDef {
        name: "studio_performance_keep".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Session,
        catalog_name: None,
        confirm_required: false,
        description: "Keep what was just played. Everything played on an instrument is held in a bounded rolling buffer whether or not anything was armed or recording; this lands that buffer as real notes in one undoable step. Read snapshot.performance.keepableNotes to see how much is there. Refuses while a record.start take is open — stop that take instead."
            .into(),
        input_schema: obj_schema(json!({}), &[]),
    });

    // THROW AWAY what was just played. The counterpart Keep shipped without,
    // which left "how do I not keep notes?" with no answer at all: the buffer
    // is a rolling 128 beats, so a bad pass and a good pass sat in the same
    // count and the only exit was to keep everything and undo it.
    //
    // Perform tier, NOT Manage, and the distinction is the point: Manage is for
    // commands that delete user CONTENT. This deletes nothing that was ever in
    // the project — the buffer holds notes that were heard and never written —
    // so demanding `confirm: true` would teach an agent that dropping an
    // unkept take is as consequential as removing a track.
    defs.push(ToolDef {
        name: "studio_performance_discard".into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Session,
        catalog_name: None,
        confirm_required: false,
        description: "Throw away what was just played, WITHOUT putting any of it in the project. The counterpart of studio_performance_keep: it empties the rolling retro-capture buffer and nothing else. It cannot touch a clip, a note or a take, journals nothing, and is therefore not undoable — there is nothing for an undo to restore. Refuses while a record.start take is open; use record.cancel for that."
            .into(),
        input_schema: obj_schema(json!({}), &[]),
    });

    defs
}

fn read_tool(name: &str, description: &str, input_schema: Value) -> ToolDef {
    ToolDef {
        name: name.into(),
        tier: ToolTier::Read,
        kind: ToolKind::Read,
        catalog_name: None,
        confirm_required: false,
        description: description.into(),
        input_schema,
    }
}

fn gen_tool(name: &str, description: &str, input_schema: Value) -> ToolDef {
    ToolDef {
        name: name.into(),
        tier: ToolTier::Perform,
        kind: ToolKind::Gen,
        catalog_name: None,
        confirm_required: false,
        description: description.into(),
        input_schema,
    }
}

fn revise_tool(name: &str, tier: ToolTier, description: &str, input_schema: Value) -> ToolDef {
    ToolDef {
        name: name.into(),
        tier,
        kind: ToolKind::Revise,
        catalog_name: None,
        confirm_required: false,
        description: description.into(),
        input_schema,
    }
}

/// Look up a tool by name.
pub fn tool_by_name(name: &str) -> Option<ToolDef> {
    tool_defs().into_iter().find(|t| t.name == name)
}

/// The committed, human-auditable manifest of the generated tool set. The
/// regen check (`tests/parity.rs`) asserts `docs/generated/mcp-tools.v1.json`
/// equals this, so the codegen output stays reviewed in git.
pub fn tools_manifest() -> Value {
    let defs = tool_defs();
    let tools: Vec<Value> = defs
        .iter()
        .map(|d| {
            let mut m = Map::new();
            m.insert("name".into(), json!(d.name));
            m.insert("tier".into(), json!(d.tier.as_str()));
            m.insert("kind".into(), json!(d.kind));
            if let Some(c) = &d.catalog_name {
                m.insert("catalogCommand".into(), json!(c));
            }
            m.insert("confirmRequired".into(), json!(d.confirm_required));
            // The DESCRIPTION, which this manifest used to omit. It is the one
            // field an agent reads first and the only part of a tool that is
            // prose rather than shape, so leaving it out made the committed,
            // reviewed artifact unable to catch the exact defect it is most
            // exposed to: a tool whose schema is perfect and whose description
            // does not say what it does. Reviewing codegen output that hides
            // the prose is reviewing half of it.
            m.insert("description".into(), json!(d.description));
            m.insert("inputSchema".into(), d.input_schema.clone());
            Value::Object(m)
        })
        .collect();
    json!({
        // Read from the embedded catalog, never hardcoded. v1.1 duplicated it
        // here as the JSON number 1.1, which is both a second source of truth
        // and numerically lossy (1.10 == 1.1). v2 onward is a string.
        "catalogVersion": timeline_core::Catalog::get().version(),
        "toolCount": tools.len(),
        "excludedCommands": EXCLUDED_COMMANDS,
        "tools": tools,
    })
}

/// Pretty-printed manifest, matching the committed file byte-for-byte
/// (`serde_json` pretty + trailing newline).
pub fn tools_manifest_pretty() -> String {
    serde_json::to_string_pretty(&tools_manifest()).expect("manifest serializes") + "\n"
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn every_catalog_command_has_a_tool_or_is_excluded() {
        let names: std::collections::HashSet<String> = tool_defs()
            .iter()
            .filter_map(|t| t.catalog_name.clone())
            .collect();
        for cmd in catalog_commands() {
            if EXCLUDED_COMMANDS.contains(&cmd.name.as_str()) {
                continue;
            }
            assert!(
                names.contains(&cmd.name),
                "catalog command {} has no tool (add a tool or a documented exclusion)",
                cmd.name
            );
        }
    }

    #[test]
    fn command_tool_count_matches_catalog_minus_exclusions() {
        let command_tools = tool_defs()
            .iter()
            .filter(|t| t.kind == ToolKind::Command)
            .count();
        assert_eq!(
            command_tools,
            catalog_commands().len() - EXCLUDED_COMMANDS.len()
        );
        // Catalog v2 is 119 commands after E1, the E2 source binding, the two
        // device.param.* setters, midi.port.role.set, the seven E5 fx commands,
        // the E5 node fader (route.node.set), track.setInputChannel,
        // record.inputListen, and the two absolute note commands
        // (note.timing.set, note.quantize); one exclusion (gen.landed) => 118
        // command tools.
        assert_eq!(command_tools, 118);
    }

    #[test]
    fn manage_tools_require_confirm_in_schema() {
        for def in tool_defs() {
            if def.tier == ToolTier::Manage {
                assert!(
                    def.confirm_required,
                    "{} manage tool must require confirm",
                    def.name
                );
                let props = def
                    .input_schema
                    .get("properties")
                    .and_then(Value::as_object);
                assert!(
                    props.is_some_and(|p| p.contains_key("confirm")),
                    "{} schema must carry confirm",
                    def.name
                );
            } else {
                assert!(
                    !def.confirm_required,
                    "{} non-manage tool must not require confirm",
                    def.name
                );
            }
        }
    }

    #[test]
    fn tool_names_are_mcp_safe_snake_case_and_unique() {
        let mut seen = std::collections::HashSet::new();
        for def in tool_defs() {
            assert!(seen.insert(def.name.clone()), "duplicate tool {}", def.name);
            assert!(
                def.name
                    .bytes()
                    .all(|c| c.is_ascii_lowercase() || c.is_ascii_digit() || c == b'_'),
                "tool {} has a non-mcp-safe char",
                def.name
            );
        }
    }
}
