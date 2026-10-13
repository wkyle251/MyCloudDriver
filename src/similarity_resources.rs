//! File descriptors are a processing resource too: GUI-launched macOS helpers
//! commonly inherit a soft limit of 256, below a 52-worker pipeline's needs.
use rustix::process::{getrlimit, setrlimit, Resource, Rlimit};

const RESERVED: u64 = 128;
const PER_WORKER: u64 = 12;

pub(super) fn prepare(workers: usize) -> usize {
    let current = getrlimit(Resource::Nofile);
    let wanted = RESERVED + PER_WORKER * workers as u64;
    if current.current.is_none_or(|limit| limit >= wanted) {
        return workers;
    }
    let target = wanted.min(current.maximum.unwrap_or(wanted));
    // Raise only this helper's soft ceiling, never the hard/system limit.
    // If the environment forbids it, admit fewer files instead of failing
    // hundreds of originals or child-process launches with EMFILE.
    let _ = setrlimit(
        Resource::Nofile,
        Rlimit {
            current: Some(target),
            maximum: current.maximum,
        },
    );
    admit(workers, getrlimit(Resource::Nofile).current)
}

fn admit(workers: usize, limit: Option<u64>) -> usize {
    limit.map_or(workers, |limit| {
        workers.min((limit.saturating_sub(RESERVED) / PER_WORKER).max(1) as usize)
    })
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn admission_preserves_headroom_and_respects_a_fixed_hard_limit() {
        assert_eq!(admit(52, Some(256)), 10);
        assert_eq!(admit(52, Some(752)), 52);
        assert_eq!(admit(52, None), 52);
        assert_eq!(admit(8, Some(256)), 8);
    }
}
