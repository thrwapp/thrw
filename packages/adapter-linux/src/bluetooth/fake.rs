use std::sync::Mutex;

use super::gateway::{BluetoothGateway, BluetoothGatewayError};

/// Fakes the [`BluetoothGateway`] boundary instead of a real BlueZ/D-Bus
/// connection, so [`super::BluetoothConnectionManager`]'s tests can run
/// without Bluetooth hardware or a running `bluetoothd` - there is
/// neither on the CI runner. Mirrors adapter-mac's
/// `FakeBluetoothPeripheralGateway` / adapter-android's
/// `FakeBluetoothClassicGateway`.
#[derive(Default)]
pub struct FakeBluetoothGateway {
    pub connect_calls: Mutex<Vec<String>>,
    pub disconnect_calls: Mutex<Vec<String>>,
    pub fail_next_connect: Mutex<bool>,
    pub fail_next_disconnect: Mutex<bool>,
}

impl BluetoothGateway for FakeBluetoothGateway {
    async fn connect(&self, device_address: &str) -> Result<(), BluetoothGatewayError> {
        self.connect_calls
            .lock()
            .unwrap()
            .push(device_address.to_string());

        let mut fail_next_connect = self.fail_next_connect.lock().unwrap();
        if *fail_next_connect {
            *fail_next_connect = false;
            return Err(BluetoothGatewayError::ConnectFailed(
                "simulated connect failure".to_string(),
            ));
        }
        Ok(())
    }

    async fn disconnect(&self, device_address: &str) -> Result<(), BluetoothGatewayError> {
        self.disconnect_calls
            .lock()
            .unwrap()
            .push(device_address.to_string());

        let mut fail_next_disconnect = self.fail_next_disconnect.lock().unwrap();
        if *fail_next_disconnect {
            *fail_next_disconnect = false;
            return Err(BluetoothGatewayError::DisconnectFailed(
                "simulated disconnect failure".to_string(),
            ));
        }
        Ok(())
    }
}
