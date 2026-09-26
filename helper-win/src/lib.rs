//! The Windows side of the VibeRDP Seam mode: the protocol, and the helper built on it

pub mod cli;
pub mod desktop;
pub mod i18n;
pub mod icon;
pub mod launcher;
pub mod layout;
pub mod protocol;
pub mod session;

/// The helper carries the version of the product: build.env names it for the app and the core as well
#[cfg(test)]
mod version {
    #[test]
    fn helper_has_the_version_of_the_product() {
        let product = include_str!("../../build.env")
            .lines()
            .find_map(|line| line.strip_prefix("VERSION="))
            .expect("build.env names VERSION");
        assert_eq!(
            env!("CARGO_PKG_VERSION"),
            product,
            "helper-win/Cargo.toml and build.env disagree"
        );
    }
}
