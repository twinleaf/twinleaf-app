// SPDX-License-Identifier: Apache-2.0

fn main() {
    // A sandboxed executable must carry a bundle identifier so libsecinit can
    // create its sandbox container; without one, the process is killed during
    // dyld startup. Embed an Info.plist into the tio-bridge binary (macOS
    // builds only) the same way the SwiftPM app target does.
    let target_os = std::env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    if target_os == "macos" {
        let manifest_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
        let plist = std::path::Path::new(&manifest_dir)
            .join("../../Packaging/TioBridge-Info.plist");
        let plist = plist.canonicalize().unwrap_or(plist);
        println!(
            "cargo:rustc-link-arg-bins=-Wl,-sectcreate,__TEXT,__info_plist,{}",
            plist.display()
        );
        println!("cargo:rerun-if-changed={}", plist.display());
    }
}
