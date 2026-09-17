use std::collections::HashMap;

use tokio::sync::Mutex;

use super::gateway::{BluetoothGateway, BluetoothGatewayError};
use super::state::BluetoothConnectionState;

/// Manages Bluetooth connect/disconnect for paired devices, one device at
/// a time per address (per ADR 0002: sequential handoff, not multipoint -
/// this type has no notion of "the other device", it just tracks state
/// per address). Mirrors adapter-mac's `BluetoothConnectionManager` /
/// adapter-android's `BluetoothConnectionManager`.
///
/// This is local device control only. It does not talk to a relay, does
/// not implement the node interface, and does not do any trigger
/// detection - see #108 and its handoff doc for scope.
pub struct BluetoothConnectionManager<G: BluetoothGateway> {
    gateway: G,
    states: Mutex<HashMap<String, BluetoothConnectionState>>,
}

impl<G: BluetoothGateway> BluetoothConnectionManager<G> {
    pub fn new(gateway: G) -> Self {
        Self {
            gateway,
            states: Mutex::new(HashMap::new()),
        }
    }

    /// Connects to `device_address`. A no-op if that device is already
    /// connected or a connection attempt is already in flight.
    ///
    /// On failure, state reverts to
    /// [`BluetoothConnectionState::Disconnected`] and the underlying
    /// error is returned.
    pub async fn connect(&self, device_address: &str) -> Result<(), BluetoothGatewayError> {
        let should_connect = {
            let mut states = self.states.lock().await;
            match states.get(device_address) {
                Some(BluetoothConnectionState::Connected)
                | Some(BluetoothConnectionState::Connecting) => false,
                _ => {
                    states.insert(
                        device_address.to_string(),
                        BluetoothConnectionState::Connecting,
                    );
                    true
                }
            }
        };
        if !should_connect {
            return Ok(());
        }

        match self.gateway.connect(device_address).await {
            Ok(()) => {
                self.states.lock().await.insert(
                    device_address.to_string(),
                    BluetoothConnectionState::Connected,
                );
                Ok(())
            }
            Err(error) => {
                self.states.lock().await.insert(
                    device_address.to_string(),
                    BluetoothConnectionState::Disconnected,
                );
                Err(error)
            }
        }
    }

    /// Disconnects `device_address`. A no-op if that device is unknown,
    /// already disconnected, or already disconnecting.
    pub async fn disconnect(&self, device_address: &str) -> Result<(), BluetoothGatewayError> {
        let should_disconnect = {
            let mut states = self.states.lock().await;
            match states.get(device_address) {
                None
                | Some(BluetoothConnectionState::Disconnected)
                | Some(BluetoothConnectionState::Disconnecting) => false,
                _ => {
                    states.insert(
                        device_address.to_string(),
                        BluetoothConnectionState::Disconnecting,
                    );
                    true
                }
            }
        };
        if !should_disconnect {
            return Ok(());
        }

        let result = self.gateway.disconnect(device_address).await;
        self.states.lock().await.insert(
            device_address.to_string(),
            BluetoothConnectionState::Disconnected,
        );
        result
    }

    /// Current known connection state for `device_address`; unknown
    /// devices report [`BluetoothConnectionState::Disconnected`].
    pub async fn connection_state(&self, device_address: &str) -> BluetoothConnectionState {
        self.states
            .lock()
            .await
            .get(device_address)
            .copied()
            .unwrap_or(BluetoothConnectionState::Disconnected)
    }
}

#[cfg(test)]
mod tests {
    use super::super::fake::FakeBluetoothGateway;
    use super::*;

    const ADDRESS: &str = "AA:BB:CC:DD:EE:FF";
    const OTHER_ADDRESS: &str = "11:22:33:44:55:66";

    #[tokio::test]
    async fn unknown_device_reports_disconnected() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Disconnected
        );
    }

    #[tokio::test]
    async fn connect_transitions_to_connected_and_calls_the_gateway_once() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());

        manager.connect(ADDRESS).await.unwrap();

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Connected
        );
        assert_eq!(
            *manager.gateway.connect_calls.lock().unwrap(),
            vec![ADDRESS.to_string()]
        );
    }

    #[tokio::test]
    async fn connect_while_already_connected_is_a_no_op() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());

        manager.connect(ADDRESS).await.unwrap();
        manager.connect(ADDRESS).await.unwrap();

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Connected
        );
        assert_eq!(
            *manager.gateway.connect_calls.lock().unwrap(),
            vec![ADDRESS.to_string()]
        );
    }

    #[tokio::test]
    async fn failed_connect_reverts_to_disconnected_and_propagates_the_error() {
        let gateway = FakeBluetoothGateway::default();
        *gateway.fail_next_connect.lock().unwrap() = true;
        let manager = BluetoothConnectionManager::new(gateway);

        let result = manager.connect(ADDRESS).await;

        assert!(result.is_err());
        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Disconnected
        );
    }

    #[tokio::test]
    async fn connect_after_a_failed_attempt_is_retried() {
        let gateway = FakeBluetoothGateway::default();
        *gateway.fail_next_connect.lock().unwrap() = true;
        let manager = BluetoothConnectionManager::new(gateway);

        assert!(manager.connect(ADDRESS).await.is_err());
        manager.connect(ADDRESS).await.unwrap();

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Connected
        );
        assert_eq!(
            *manager.gateway.connect_calls.lock().unwrap(),
            vec![ADDRESS.to_string(), ADDRESS.to_string()]
        );
    }

    #[tokio::test]
    async fn disconnect_transitions_a_connected_device_back_to_disconnected() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());
        manager.connect(ADDRESS).await.unwrap();

        manager.disconnect(ADDRESS).await.unwrap();

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Disconnected
        );
        assert_eq!(
            *manager.gateway.disconnect_calls.lock().unwrap(),
            vec![ADDRESS.to_string()]
        );
    }

    #[tokio::test]
    async fn disconnecting_an_unknown_device_is_a_no_op_that_never_calls_the_gateway() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());

        manager.disconnect(ADDRESS).await.unwrap();

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Disconnected
        );
        assert!(manager.gateway.disconnect_calls.lock().unwrap().is_empty());
    }

    #[tokio::test]
    async fn disconnecting_an_already_disconnected_device_does_not_call_the_gateway_again() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());
        manager.connect(ADDRESS).await.unwrap();
        manager.disconnect(ADDRESS).await.unwrap();

        manager.disconnect(ADDRESS).await.unwrap();

        assert_eq!(
            *manager.gateway.disconnect_calls.lock().unwrap(),
            vec![ADDRESS.to_string()]
        );
    }

    #[tokio::test]
    async fn even_a_failed_disconnect_leaves_state_disconnected() {
        let gateway = FakeBluetoothGateway::default();
        let manager = BluetoothConnectionManager::new(gateway);
        manager.connect(ADDRESS).await.unwrap();
        *manager.gateway.fail_next_disconnect.lock().unwrap() = true;

        let result = manager.disconnect(ADDRESS).await;

        assert!(result.is_err());
        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Disconnected
        );
    }

    #[tokio::test]
    async fn each_device_address_is_tracked_independently() {
        let manager = BluetoothConnectionManager::new(FakeBluetoothGateway::default());

        manager.connect(ADDRESS).await.unwrap();

        assert_eq!(
            manager.connection_state(ADDRESS).await,
            BluetoothConnectionState::Connected
        );
        assert_eq!(
            manager.connection_state(OTHER_ADDRESS).await,
            BluetoothConnectionState::Disconnected
        );
    }
}
