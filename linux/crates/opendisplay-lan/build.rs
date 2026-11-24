use std::{env, path::PathBuf, process::Command};

fn main() {
    let source = PathBuf::from(env!("CARGO_MANIFEST_DIR")).join("../../../Pairing");
    let build = PathBuf::from(env::var_os("OUT_DIR").unwrap()).join("pairing");
    println!("cargo:rerun-if-changed={}", source.display());
    println!("cargo:rerun-if-env-changed=OD_BORINGSSL_SOURCE");
    let mut configure = Command::new("cmake");
    configure
        .args(["-S"])
        .arg(source)
        .args(["-B"])
        .arg(&build)
        .arg("-DCMAKE_BUILD_TYPE=Release");
    if let Ok(path) = env::var("OD_BORINGSSL_SOURCE") {
        configure.arg(format!("-DFETCHCONTENT_SOURCE_DIR_BORINGSSL={path}"));
    }
    assert!(
        configure
            .status()
            .expect("run CMake for LAN pairing")
            .success()
    );
    assert!(
        Command::new("cmake")
            .arg("--build")
            .arg(&build)
            .args(["--target", "odpair", "--parallel", "4"])
            .status()
            .expect("build LAN pairing")
            .success()
    );
    println!("cargo:rustc-link-search=native={}", build.display());
    println!(
        "cargo:rustc-link-search=native={}",
        build.join("_deps/boringssl-build").display()
    );
    println!("cargo:rustc-link-lib=static=odpair");
    println!("cargo:rustc-link-lib=static=crypto");
    if env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        println!("cargo:rustc-link-lib=c++");
        println!("cargo:rustc-link-lib=framework=Security");
    } else {
        println!("cargo:rustc-link-lib=stdc++");
    }
}
