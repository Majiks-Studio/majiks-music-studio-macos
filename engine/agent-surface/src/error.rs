//! One error type for the whole agent surface. Each transport maps it to its
//! own boundary form: FFI to a typed `FfiError`, MCP to a JSON-RPC `ErrorData`,
//! the CLI to a nonzero exit + message. Every variant carries a `code()` so
//! agents can branch on it without string-matching prose.

use std::fmt;

use timeline_core::CommandError;

#[derive(Debug, Clone, PartialEq)]
pub enum StudioError {
    /// No project is open (call initialize / project.new / project.open first).
    NotInitialized(String),
    /// A parameter or envelope failed validation before it reached the bus.
    InvalidArgument(String),
    /// The command bus rejected the command (unknown command, bad params,
    /// overlap, unknown id, out of range...). Carries the catalog error code.
    Command { code: String, message: String },
    /// Filesystem / package io failure.
    Io(String),
    /// Audio decode / render / bounce failure.
    Audio(String),
    /// A gen proxy call failed or the gen backend is not configured.
    Gen(String),
    /// The MCP write rate limit tripped.
    RateLimited(String),
    /// A Manage-tier tool was called without `confirm: true`.
    ConfirmationRequired(String),
    /// The caller asked for something out of this surface's scope.
    Unsupported(String),
}

impl StudioError {
    /// Stable machine code (never prose). Mirrors the catalog `CommandError`
    /// codes for the `Command` variant.
    pub fn code(&self) -> &str {
        match self {
            StudioError::NotInitialized(_) => "not_initialized",
            StudioError::InvalidArgument(_) => "invalid_argument",
            StudioError::Command { code, .. } => code,
            StudioError::Io(_) => "io_error",
            StudioError::Audio(_) => "audio_error",
            StudioError::Gen(_) => "gen_error",
            StudioError::RateLimited(_) => "rate_limited",
            StudioError::ConfirmationRequired(_) => "confirmation_required",
            StudioError::Unsupported(_) => "unsupported",
        }
    }

    pub fn message(&self) -> String {
        match self {
            StudioError::NotInitialized(m)
            | StudioError::InvalidArgument(m)
            | StudioError::Io(m)
            | StudioError::Audio(m)
            | StudioError::Gen(m)
            | StudioError::RateLimited(m)
            | StudioError::ConfirmationRequired(m)
            | StudioError::Unsupported(m) => m.clone(),
            StudioError::Command { message, .. } => message.clone(),
        }
    }

    pub fn io(m: impl fmt::Display) -> Self {
        StudioError::Io(m.to_string())
    }

    pub fn audio(m: impl fmt::Display) -> Self {
        StudioError::Audio(m.to_string())
    }

    pub fn invalid(m: impl Into<String>) -> Self {
        StudioError::InvalidArgument(m.into())
    }
}

impl fmt::Display for StudioError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(f, "[{}] {}", self.code(), self.message())
    }
}

impl std::error::Error for StudioError {}

impl From<CommandError> for StudioError {
    fn from(e: CommandError) -> Self {
        StudioError::Command {
            code: e.code().to_string(),
            message: e.to_string(),
        }
    }
}
