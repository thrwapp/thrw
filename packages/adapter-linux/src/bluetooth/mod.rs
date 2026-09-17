//! Bluetooth connection management for a single paired device, backed by
//! BlueZ over D-Bus. Scoped to local device control only - see #108's
//! handoff doc (`docs/handoffs/108.md`) for what is and isn't covered.

mod bluez_gateway;
mod connection_manager;
mod gateway;
mod state;

#[cfg(test)]
mod fake;

pub use bluez_gateway::BluezBluetoothGateway;
pub use connection_manager::BluetoothConnectionManager;
pub use gateway::{BluetoothGateway, BluetoothGatewayError};
pub use state::BluetoothConnectionState;

#[cfg(test)]
pub use fake::FakeBluetoothGateway;
