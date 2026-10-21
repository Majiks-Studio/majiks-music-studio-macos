//! Allocation guard: an allocation-counting global allocator plus a
//! render-scope marker.
//!
//! The render core calls `enter_render_scope()` / `leave_render_scope()`
//! around every block it renders. When a binary installs `CountingAlloc` as
//! its global allocator (the proof harness and the integration tests do),
//! any allocation or free performed by THAT thread while it is inside the
//! scope increments `VIOLATIONS`. The counter never panics and never prints;
//! the allocator must stay reentrancy-safe, so callers read `violations()`
//! and assert.
//!
//! Thread identity is a THREAD-LOCAL depth counter, not a global table keyed
//! by `pthread_self()`. The earlier global-table design mis-attributed a
//! long-lived helper thread's allocations to a render scope over long
//! multi-threaded runs (a stale slot from an OS-torn-down audio thread could
//! alias a recycled `pthread_t`): a 30-minute live probe on a macOS aggregate
//! output device counted tens of thousands of phantom "violations" while the
//! authoritative single-thread offline test — the identical `render()`
//! hammered through this same allocator — stayed at exactly 0. A thread-local
//! counter is immune to `pthread_t` recycling and cross-thread aliasing: each
//! thread only ever sees its own depth, so only the thread actually executing
//! `render()` is ever counted.
//!
//! When the guard allocator is not installed (library consumers), the scope
//! markers are two thread-local reads/writes per block and nothing else.

use std::alloc::{GlobalAlloc, Layout, System};
use std::cell::Cell;
use std::sync::atomic::{AtomicU64, Ordering};

thread_local! {
    // const-initialized so first access never lazily allocates (safe to
    // touch from inside the global allocator without recursion).
    static RENDER_DEPTH: Cell<u32> = const { Cell::new(0) };
}

static VIOLATIONS: AtomicU64 = AtomicU64::new(0);

/// Mark the current thread as being inside a render scope. Re-entrant: a
/// depth counter, so nested enters and multiple live render cores (each on
/// its own thread) are all handled. Never blocks, never allocates.
#[inline]
pub fn enter_render_scope() {
    let _ = RENDER_DEPTH.try_with(|d| d.set(d.get().saturating_add(1)));
}

#[inline]
pub fn leave_render_scope() {
    let _ = RENDER_DEPTH.try_with(|d| d.set(d.get().saturating_sub(1)));
}

/// Total allocator hits observed inside render scopes since process start.
pub fn violations() -> u64 {
    VIOLATIONS.load(Ordering::Relaxed)
}

#[inline]
fn record_if_guarded() {
    // try_with tolerates TLS teardown during thread exit; const init means
    // this access itself cannot allocate, so no allocator recursion.
    let in_scope = RENDER_DEPTH.try_with(|d| d.get() > 0).unwrap_or(false);
    if in_scope {
        VIOLATIONS.fetch_add(1, Ordering::Relaxed);
    }
}

/// Counting allocator wrapper around the system allocator. Install with
/// `#[global_allocator]` in proof binaries and tests.
pub struct CountingAlloc;

unsafe impl GlobalAlloc for CountingAlloc {
    unsafe fn alloc(&self, layout: Layout) -> *mut u8 {
        record_if_guarded();
        unsafe { System.alloc(layout) }
    }

    unsafe fn dealloc(&self, ptr: *mut u8, layout: Layout) {
        record_if_guarded();
        unsafe { System.dealloc(ptr, layout) }
    }

    unsafe fn alloc_zeroed(&self, layout: Layout) -> *mut u8 {
        record_if_guarded();
        unsafe { System.alloc_zeroed(layout) }
    }

    unsafe fn realloc(&self, ptr: *mut u8, layout: Layout, new_size: usize) -> *mut u8 {
        record_if_guarded();
        unsafe { System.realloc(ptr, layout, new_size) }
    }
}
