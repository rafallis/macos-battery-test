//! DYLD interposition dylib — spoofs `CycleCount` in IOKit reads.
//!
//! Build (arm64):
//!   cargo build --release --target aarch64-apple-darwin
//!
//! The dylib is injected at process startup by dyld when the environment
//! variable `DYLD_INSERT_LIBRARIES` points to this dylib.  The spoofed value
//! to return is read from `MACBATTERY_CYCLE_COUNT`.
//!
//! REQUIREMENTS:
//!   - SIP disabled (`csrutil disable`)
//!   - For hardened-runtime system apps (System Settings) additionally set
//!     the `amfi_get_out_of_my_way=1` boot argument.

#![allow(non_upper_case_globals)]
#![allow(non_camel_case_types)]
#![allow(non_snake_case)]

use core_foundation::base::{CFAllocatorRef, CFTypeRef, TCFType};
use core_foundation::number::{CFNumber, CFNumberRef};
use core_foundation::string::CFString;
use core_foundation_sys::base::{kCFAllocatorDefault, CFIndex};
use core_foundation_sys::string::CFStringRef;
use io_kit_sys::types::io_registry_entry_t;
use libc::c_uint;
use std::ffi::CStr;
use std::os::raw::c_char;
use std::sync::OnceLock;

// ---------------------------------------------------------------------------
// Constant for IORegistryEntryCreateCFProperty options argument
// ---------------------------------------------------------------------------
type IOOptionBits = c_uint;

// ---------------------------------------------------------------------------
// Link to the real IORegistryEntryCreateCFProperty from IOKit
// ---------------------------------------------------------------------------
extern "C" {
    // The real symbol lives in IOKit.framework.  We link against it here so
    // DYLD resolves it at load time; the interpose table below replaces use
    // of this symbol in *other* images (not in this dylib itself).
    fn IORegistryEntryCreateCFProperty(
        entry: io_registry_entry_t,
        key: CFStringRef,
        allocator: CFAllocatorRef,
        options: IOOptionBits,
    ) -> CFTypeRef;

    fn IORegistryEntryCreateCFProperties(
        entry: io_registry_entry_t,
        properties: *mut core_foundation_sys::dictionary::CFMutableDictionaryRef,
        allocator: CFAllocatorRef,
        options: IOOptionBits,
    ) -> i32; // kern_return_t
}

// ---------------------------------------------------------------------------
// Spoofed value cache — read once from env, reuse for every call
// ---------------------------------------------------------------------------
static SPOOFED_COUNT: OnceLock<Option<i64>> = OnceLock::new();

fn spoofed_cycle_count() -> Option<i64> {
    *SPOOFED_COUNT.get_or_init(|| {
        std::env::var("MACBATTERY_CYCLE_COUNT")
            .ok()
            .and_then(|v| v.trim().parse::<i64>().ok())
    })
}

// ---------------------------------------------------------------------------
// Helper: compare a CFStringRef to a Rust &str without allocation
// ---------------------------------------------------------------------------
fn cfstring_eq(cf: CFStringRef, s: &str) -> bool {
    if cf.is_null() {
        return false;
    }
    // SAFETY: cf is non-null and this is a read-only comparison.
    let rust_cf = unsafe { CFString::wrap_under_get_rule(cf) };
    rust_cf.to_string() == s
}

// ---------------------------------------------------------------------------
// Replacement for IORegistryEntryCreateCFProperty
// ---------------------------------------------------------------------------
unsafe extern "C" fn hooked_IORegistryEntryCreateCFProperty(
    entry: io_registry_entry_t,
    key: CFStringRef,
    allocator: CFAllocatorRef,
    options: IOOptionBits,
) -> CFTypeRef {
    if let Some(count) = spoofed_cycle_count() {
        if cfstring_eq(key, "CycleCount") {
            // Return a retained CFNumber with the spoofed value.
            let n = CFNumber::from(count as i32);
            // `into_CFType()` consumes the Rust wrapper and gives us an
            // unbalanced retain — correct for a Create-rule return.
            return n.into_CFType().as_CFTypeRef() as CFTypeRef;
        }
    }
    // Fall through to the real implementation.
    IORegistryEntryCreateCFProperty(entry, key, allocator, options)
}

// ---------------------------------------------------------------------------
// Replacement for IORegistryEntryCreateCFProperties
// Patches "CycleCount" inside the returned mutable dictionary.
// ---------------------------------------------------------------------------
unsafe extern "C" fn hooked_IORegistryEntryCreateCFProperties(
    entry: io_registry_entry_t,
    properties: *mut core_foundation_sys::dictionary::CFMutableDictionaryRef,
    allocator: CFAllocatorRef,
    options: IOOptionBits,
) -> i32 {
    let kr = IORegistryEntryCreateCFProperties(entry, properties, allocator, options);
    if kr != 0 || properties.is_null() {
        return kr;
    }
    if let Some(count) = spoofed_cycle_count() {
        let dict = *properties;
        if !dict.is_null() {
            let key = CFString::new("CycleCount");
            let num = CFNumber::from(count as i32);
            // SAFETY: dict is a valid CFMutableDictionaryRef from IOKit.
            core_foundation_sys::dictionary::CFDictionarySetValue(
                dict,
                key.as_CFTypeRef() as *const _,
                num.as_CFTypeRef() as *const _,
            );
        }
    }
    kr
}

// ---------------------------------------------------------------------------
// DYLD interpose table
//
// Each entry is { replacement, original }.  `dyld` scans the
// `__DATA,__interpose` section at load time and redirects all calls to
// `original` (from other images) to `replacement`.
// ---------------------------------------------------------------------------
#[repr(C)]
struct InterposeEntry {
    replacement: *const (),
    original: *const (),
}

// SAFETY: These are plain function pointers — safe to share across threads.
unsafe impl Sync for InterposeEntry {}

#[link_section = "__DATA,__interpose"]
#[used]
static INTERPOSE_TABLE: [InterposeEntry; 2] = [
    InterposeEntry {
        replacement: hooked_IORegistryEntryCreateCFProperty as *const (),
        original: IORegistryEntryCreateCFProperty as *const (),
    },
    InterposeEntry {
        replacement: hooked_IORegistryEntryCreateCFProperties as *const (),
        original: IORegistryEntryCreateCFProperties as *const (),
    },
];

// ---------------------------------------------------------------------------
// Optional: log injection on load (visible in Console.app / stderr)
// ---------------------------------------------------------------------------
#[cfg(target_os = "macos")]
#[link_section = "__DATA_CONST,__mod_init_func"]
#[used]
static INIT: extern "C" fn() = {
    extern "C" fn initializer() {
        if let Some(count) = spoofed_cycle_count() {
            eprintln!(
                "[cyclecount-hook] loaded — CycleCount will be spoofed to {}",
                count
            );
        } else {
            eprintln!(
                "[cyclecount-hook] loaded — MACBATTERY_CYCLE_COUNT not set, pass-through mode"
            );
        }
    }
    initializer
};
