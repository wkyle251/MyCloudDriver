//! Physical device metadata only. APFS volumes ascend to the same storage
//! device, so sibling volumes share a verification queue. No file data is read.
use std::{
    ffi::{c_char, c_void, CString},
    ptr,
};

type CF = *const c_void;
#[derive(Debug, PartialEq, Eq)]
pub(super) enum Medium {
    Rotating(u64),
    SolidState,
    Unknown,
}

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOBSDNameMatching(port: u32, options: u32, name: *const c_char) -> CF;
    fn IOServiceGetMatchingService(port: u32, matching: CF) -> u32;
    fn IOObjectConformsTo(object: u32, class: *const c_char) -> u32;
    fn IOObjectRelease(object: u32) -> i32;
    fn IORegistryEntryGetParentEntry(entry: u32, plane: *const c_char, parent: *mut u32) -> i32;
    fn IORegistryEntryGetRegistryEntryID(entry: u32, id: *mut u64) -> i32;
    fn IORegistryEntryCreateCFProperty(entry: u32, key: CF, allocator: CF, options: u32) -> CF;
}
#[link(name = "CoreFoundation", kind = "framework")]
extern "C" {
    fn CFStringCreateWithCString(allocator: CF, text: *const c_char, encoding: u32) -> CF;
    fn CFGetTypeID(value: CF) -> usize;
    fn CFDictionaryGetTypeID() -> usize;
    fn CFStringGetTypeID() -> usize;
    fn CFDictionaryGetValue(dictionary: CF, key: CF) -> CF;
    fn CFStringGetCString(value: CF, buffer: *mut c_char, capacity: isize, encoding: u32) -> u8;
    fn CFRelease(value: CF);
}

struct Service(u32);
impl Drop for Service {
    fn drop(&mut self) {
        unsafe {
            IOObjectRelease(self.0);
        }
    }
}
struct Property(CF);
impl Drop for Property {
    fn drop(&mut self) {
        unsafe {
            CFRelease(self.0);
        }
    }
}
impl Property {
    fn string(text: &std::ffi::CStr) -> Option<Self> {
        let value = unsafe { CFStringCreateWithCString(ptr::null(), text.as_ptr(), 0x08000100) };
        (!value.is_null()).then(|| Self(value))
    }
}

fn storage_medium(service: &Service) -> Medium {
    let Some(key) = Property::string(c"Device Characteristics") else {
        return Medium::Unknown;
    };
    let dictionary = unsafe { IORegistryEntryCreateCFProperty(service.0, key.0, ptr::null(), 0) };
    if dictionary.is_null() {
        return Medium::Unknown;
    }
    let dictionary = Property(dictionary);
    if unsafe { CFGetTypeID(dictionary.0) != CFDictionaryGetTypeID() } {
        return Medium::Unknown;
    }
    let Some(key) = Property::string(c"Medium Type") else {
        return Medium::Unknown;
    };
    let value = unsafe { CFDictionaryGetValue(dictionary.0, key.0) };
    if value.is_null() || unsafe { CFGetTypeID(value) != CFStringGetTypeID() } {
        return Medium::Unknown;
    }
    let mut buffer = [0 as c_char; 64];
    if unsafe {
        CFStringGetCString(
            value,
            buffer.as_mut_ptr(),
            buffer.len() as isize,
            0x08000100,
        )
    } == 0
    {
        return Medium::Unknown;
    }
    let name = unsafe { std::ffi::CStr::from_ptr(buffer.as_ptr()) }.to_bytes();
    if name == b"Solid State" {
        return Medium::SolidState;
    }
    if name != b"Rotational" {
        return Medium::Unknown;
    }
    let mut id = 0;
    if unsafe { IORegistryEntryGetRegistryEntryID(service.0, &mut id) } == 0 {
        Medium::Rotating(id)
    } else {
        Medium::Unknown
    }
}

pub(super) fn medium(bsd: &[u8]) -> Medium {
    let Ok(name) = CString::new(bsd) else {
        return Medium::Unknown;
    };
    // IOServiceGetMatchingService consumes the dictionary even on failure.
    let matching = unsafe { IOBSDNameMatching(0, 0, name.as_ptr()) };
    if matching.is_null() {
        return Medium::Unknown;
    }
    let service = unsafe { IOServiceGetMatchingService(0, matching) };
    if service == 0 {
        return Medium::Unknown;
    }
    let mut current = Service(service);
    for _ in 0..64 {
        if unsafe { IOObjectConformsTo(current.0, c"IOBlockStorageDevice".as_ptr()) } != 0 {
            return storage_medium(&current);
        }
        let mut parent = 0;
        if unsafe { IORegistryEntryGetParentEntry(current.0, c"IOService".as_ptr(), &mut parent) }
            != 0
            || parent == 0
        {
            break;
        }
        current = Service(parent);
    }
    Medium::Unknown
}
