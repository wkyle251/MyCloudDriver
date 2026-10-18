//! Host memory signals and accounting shared with an original-buffer provider.
use std::sync::atomic::{AtomicU64, Ordering};

#[derive(Debug, Default)]
pub struct ExternalMemory {
    pub used: AtomicU64,
    pub limit: AtomicU64,
    pub incomplete: AtomicU64,
    pub completion_required: AtomicU64,
}
impl ExternalMemory {
    pub fn committed(&self) -> u64 {
        self.used.load(Ordering::Acquire).max(self.limit.load(Ordering::Acquire))
    }
}

#[derive(Debug, Clone, Copy)]
pub struct SystemMemory {
    pub physical_bytes: u64,
    /// macOS levels: 1 normal, 2 warning, 4 critical.
    pub pressure: u32,
}

pub fn system_memory() -> SystemMemory {
    #[cfg(target_os = "macos")]
    {
        fn read<T: Default>(name: &[u8]) -> Option<T> {
            let mut value = T::default();
            let mut size = std::mem::size_of::<T>();
            // Both names and output types are fixed by the callers below.
            let result = unsafe { libc::sysctlbyname(name.as_ptr().cast(), (&mut value as *mut T).cast(), &mut size, std::ptr::null_mut(), 0) };
            (result == 0 && size == std::mem::size_of::<T>()).then_some(value)
        }
        SystemMemory {
            physical_bytes: read::<u64>(b"hw.memsize\0").unwrap_or(4 << 30),
            pressure: read::<u32>(b"kern.memorystatus_vm_pressure_level\0").unwrap_or(1),
        }
    }
    #[cfg(target_os = "linux")]
    {
        let info = std::fs::read_to_string("/proc/meminfo").unwrap_or_default();
        let field = |key: &str| info.lines().find_map(|line| line.strip_prefix(key)?.split_whitespace().next()?.parse::<u64>().ok()).unwrap_or(0) * 1024;
        let physical = field("MemTotal:").max(512 << 20);
        let available = field("MemAvailable:");
        let pressure = if available < physical / 20 { 4 } else if available < physical / 10 { 2 } else { 1 };
        SystemMemory { physical_bytes: physical, pressure }
    }
}
