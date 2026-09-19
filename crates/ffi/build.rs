fn main() {
    let crate_dir = std::env::var("CARGO_MANIFEST_DIR").unwrap();
    // Falling back to the default config on a parse error would silently
    // change the generated header, so fail the build instead.
    let config = cbindgen::Config::from_file("cbindgen.toml").expect("invalid cbindgen.toml");
    cbindgen::Builder::new()
        .with_crate(&crate_dir)
        .with_config(config)
        .generate()
        .expect("Unable to generate FFI bindings")
        .write_to_file("binding.h");
}
