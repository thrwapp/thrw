pub mod bluetooth;

pub const ADAPTER_NAME: &str = "adapter-linux";

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn adapter_name_is_set() {
        assert_eq!(ADAPTER_NAME, "adapter-linux");
    }
}
