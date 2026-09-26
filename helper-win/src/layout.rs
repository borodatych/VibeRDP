//! Which of the keyboard layouts of the session serves a language, section 7 of protocol/seam-protocol.md
//!
//! A layout handle carries its language in its low word; the client names a language, "ru-RU" or "ru",
//! and the layout of that exact language wins over one that only shares its primary language

/// The primary language of a language identifier: its low ten bits
const PRIMARY_MASK: u16 = 0x03FF;

/// The position of the layout for this language among the languages of the installed layouts
pub fn matching(installed: &[u16], language: u16) -> Option<usize> {
    installed.iter().position(|&id| id == language).or_else(|| {
        installed
            .iter()
            .position(|&id| id & PRIMARY_MASK == language & PRIMARY_MASK)
    })
}

#[cfg(test)]
mod tests {
    use super::*;

    const EN_US: u16 = 0x0409;
    const EN_GB: u16 = 0x0809;
    const RU_RU: u16 = 0x0419;
    /// What LocaleNameToLCID gives for the neutral "ru"
    const RU: u16 = 0x0019;

    #[test]
    fn exact_language_wins_then_the_primary_one() {
        let installed = [EN_GB, RU_RU, EN_US];
        assert_eq!(matching(&installed, EN_US), Some(2));
        assert_eq!(matching(&installed, RU), Some(1));
        assert_eq!(matching(&[EN_GB], EN_US), Some(0));
        assert_eq!(matching(&installed, 0x0407), None);
    }
}
