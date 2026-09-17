use std::str::FromStr;

use bluer::{Address, Adapter, Device, Session};

use super::gateway::{BluetoothGateway, BluetoothGatewayError};

/// Real [`BluetoothGateway`], backed by BlueZ over D-Bus via the `bluer`
/// crate (docs/spec/architecture.md names BlueZ as this platform's
/// Bluetooth backend - see docs/handoffs/108.md for why `bluer` was
/// chosen). `device_address` is the device's MAC address (e.g.
/// `"AA:BB:CC:DD:EE:FF"`); the device must already be paired with BlueZ -
/// this type never scans or pairs, matching adapter-mac's
/// `IOBluetoothPeripheralGateway` / adapter-android's
/// `AndroidBluetoothClassicGateway`, which both make the same
/// "already paired" assumption for their own platforms.
pub struct BluezBluetoothGateway {
    session: Session,
    adapter_name: Option<String>,
}

impl BluezBluetoothGateway {
    /// Opens a session with BlueZ over D-Bus and uses the system's
    /// default Bluetooth adapter (BlueZ's own notion of "default" -
    /// usually the only adapter present on a headless Linux node).
    pub async fn new() -> bluer::Result<Self> {
        let session = Session::new().await?;
        Ok(Self {
            session,
            adapter_name: None,
        })
    }

    /// Opens a session with BlueZ and pins to the named adapter (e.g.
    /// `"hci0"`) rather than whichever one BlueZ reports as default.
    pub async fn with_adapter(adapter_name: impl Into<String>) -> bluer::Result<Self> {
        let session = Session::new().await?;
        Ok(Self {
            session,
            adapter_name: Some(adapter_name.into()),
        })
    }

    async fn adapter(&self) -> bluer::Result<Adapter> {
        match &self.adapter_name {
            Some(name) => self.session.adapter(name),
            None => self.session.default_adapter().await,
        }
    }

    async fn device(&self, device_address: &str) -> Result<Device, String> {
        let address = Address::from_str(device_address)
            .map_err(|error| format!("invalid device address {device_address:?}: {error}"))?;
        let adapter = self.adapter().await.map_err(|error| error.to_string())?;
        adapter.device(address).map_err(|error| error.to_string())
    }
}

impl BluetoothGateway for BluezBluetoothGateway {
    async fn connect(&self, device_address: &str) -> Result<(), BluetoothGatewayError> {
        let device = self
            .device(device_address)
            .await
            .map_err(BluetoothGatewayError::ConnectFailed)?;
        device
            .connect()
            .await
            .map_err(|error| BluetoothGatewayError::ConnectFailed(error.to_string()))
    }

    async fn disconnect(&self, device_address: &str) -> Result<(), BluetoothGatewayError> {
        let device = self
            .device(device_address)
            .await
            .map_err(BluetoothGatewayError::DisconnectFailed)?;
        device
            .disconnect()
            .await
            .map_err(|error| BluetoothGatewayError::DisconnectFailed(error.to_string()))
    }
}
