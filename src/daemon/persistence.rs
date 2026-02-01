//! Connection state persistence for auto-reconnect on daemon restart
//!
//! This module manages persistent storage of VPN connection state to enable
//! automatic reconnection after daemon restart or system reboot.
//!
//! The state file stores:
//! - Desired connection state (connected vs disconnected)
//! - WireGuard configuration
//! - Last known connection info
//!
//! On daemon startup, if desired_state is "connected", the daemon will
//! automatically attempt to reconnect using the stored config.

use serde::{Deserialize, Serialize};
use std::path::PathBuf;

/// Desired connection state - whether the user wants to be connected
#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "snake_case")]
pub enum DesiredState {
    Connected,
    Disconnected,
}

impl Default for DesiredState {
    fn default() -> Self {
        Self::Disconnected
    }
}

/// Persistent connection state stored to disk
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct ConnectionStateFile {
    /// Schema version for future migrations
    pub schema_version: u32,
    /// User's desired state - connected or disconnected
    pub desired_state: DesiredState,
    /// WireGuard config string (if available)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub config: Option<String>,
    /// VPN IP address from last connection
    #[serde(skip_serializing_if = "Option::is_none")]
    pub vpn_ip: Option<String>,
    /// Server endpoint from last connection
    #[serde(skip_serializing_if = "Option::is_none")]
    pub server_endpoint: Option<String>,
    /// Timestamp of last successful connection (Unix epoch seconds)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub last_connected_at: Option<String>,
    /// Timestamp when state was last updated (Unix epoch seconds)
    pub last_updated_at: String,
    /// Current retry count (for auto-reconnect)
    #[serde(default)]
    pub retry_count: u32,
}

impl Default for ConnectionStateFile {
    fn default() -> Self {
        Self {
            schema_version: 1,
            desired_state: DesiredState::Disconnected,
            config: None,
            vpn_ip: None,
            server_endpoint: None,
            last_connected_at: None,
            last_updated_at: iso_now(),
            retry_count: 0,
        }
    }
}

/// Get platform-specific state directory
pub fn get_state_dir() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        PathBuf::from(r"C:\ProgramData\SecureGuard")
    }

    #[cfg(not(target_os = "windows"))]
    {
        PathBuf::from("/var/lib/secureguard")
    }
}

/// Get full path to connection state file
pub fn get_state_file_path() -> PathBuf {
    get_state_dir().join("connection-state.json")
}

/// Ensure state directory exists with correct permissions
pub fn ensure_state_dir() -> std::io::Result<()> {
    let dir = get_state_dir();
    if !dir.exists() {
        std::fs::create_dir_all(&dir)?;

        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            std::fs::set_permissions(&dir, std::fs::Permissions::from_mode(0o750))?;
        }
    }
    Ok(())
}

/// Load connection state from persistent storage
///
/// Returns None if:
/// - State file doesn't exist
/// - State file is corrupted/unparseable
pub fn load_connection_state() -> Option<ConnectionStateFile> {
    let path = get_state_file_path();

    match std::fs::read_to_string(&path) {
        Ok(json) => {
            match serde_json::from_str(&json) {
                Ok(state) => {
                    tracing::debug!("Loaded connection state from {:?}", path);
                    Some(state)
                }
                Err(e) => {
                    tracing::warn!("Failed to parse connection state file: {} - starting fresh", e);
                    None
                }
            }
        }
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => {
            tracing::debug!("No connection state file found at {:?}", path);
            None
        }
        Err(e) => {
            tracing::warn!("Failed to read connection state file: {}", e);
            None
        }
    }
}

/// Save connection state to persistent storage
///
/// Creates the state directory if it doesn't exist.
pub fn save_connection_state(state: &ConnectionStateFile) -> Result<(), std::io::Error> {
    // Ensure directory exists
    if let Err(e) = ensure_state_dir() {
        tracing::warn!("Failed to create state directory: {}", e);
        return Err(e);
    }

    let path = get_state_file_path();
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;

    std::fs::write(&path, json)?;

    // Set file permissions on Unix (readable by secureguard group)
    #[cfg(unix)]
    {
        use std::os::unix::fs::PermissionsExt;
        std::fs::set_permissions(&path, std::fs::Permissions::from_mode(0o640)).ok();
    }

    tracing::debug!("Saved connection state to {:?}", path);
    Ok(())
}

/// Delete the connection state file
///
/// Used when user explicitly disconnects or for clean uninstall.
pub fn delete_connection_state() {
    let path = get_state_file_path();
    if let Err(e) = std::fs::remove_file(&path) {
        if e.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!("Failed to delete connection state file: {}", e);
        }
    } else {
        tracing::debug!("Deleted connection state file");
    }
}

/// Update just the desired state (for quick disconnect without losing config)
pub fn update_desired_state(desired_state: DesiredState) -> Result<(), std::io::Error> {
    let mut state = load_connection_state().unwrap_or_default();
    state.desired_state = desired_state;
    state.last_updated_at = iso_now();
    save_connection_state(&state)
}

/// Update the last_connected_at timestamp (on successful connection)
pub fn update_last_connected() -> Result<(), std::io::Error> {
    if let Some(mut state) = load_connection_state() {
        state.last_connected_at = Some(iso_now());
        state.retry_count = 0;
        state.last_updated_at = iso_now();
        save_connection_state(&state)
    } else {
        Ok(()) // No state file, nothing to update
    }
}

/// Update retry count (for auto-reconnect progress tracking)
pub fn update_retry_count(count: u32) -> Result<(), std::io::Error> {
    if let Some(mut state) = load_connection_state() {
        state.retry_count = count;
        state.last_updated_at = iso_now();
        save_connection_state(&state)
    } else {
        Ok(())
    }
}

/// Get current timestamp as Unix epoch seconds string
pub fn iso_now() -> String {
    use std::time::{SystemTime, UNIX_EPOCH};
    let duration = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default();
    duration.as_secs().to_string()
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_connection_state_serialization() {
        let state = ConnectionStateFile {
            schema_version: 1,
            desired_state: DesiredState::Connected,
            config: Some("[Interface]\nPrivateKey = test\n".to_string()),
            vpn_ip: Some("10.0.0.2".to_string()),
            server_endpoint: Some("vpn.example.com:51820".to_string()),
            last_connected_at: Some("1706600000".to_string()),
            last_updated_at: "1706600100".to_string(),
            retry_count: 3,
        };

        // Serialize
        let json = serde_json::to_string_pretty(&state).unwrap();
        assert!(json.contains("\"desired_state\": \"connected\""));
        assert!(json.contains("10.0.0.2"));
        assert!(json.contains("vpn.example.com"));

        // Deserialize
        let parsed: ConnectionStateFile = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.desired_state, DesiredState::Connected);
        assert_eq!(parsed.vpn_ip, Some("10.0.0.2".to_string()));
        assert_eq!(parsed.retry_count, 3);
    }

    #[test]
    fn test_connection_state_without_optional_fields() {
        let state = ConnectionStateFile {
            schema_version: 1,
            desired_state: DesiredState::Disconnected,
            config: None,
            vpn_ip: None,
            server_endpoint: None,
            last_connected_at: None,
            last_updated_at: "0".to_string(),
            retry_count: 0,
        };

        let json = serde_json::to_string(&state).unwrap();
        // Optional None fields should not appear in JSON
        assert!(!json.contains("config"));
        assert!(!json.contains("vpn_ip"));
        assert!(!json.contains("server_endpoint"));
        assert!(!json.contains("last_connected_at"));

        // Should still deserialize correctly
        let parsed: ConnectionStateFile = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.config, None);
        assert_eq!(parsed.desired_state, DesiredState::Disconnected);
    }

    #[test]
    fn test_default_state() {
        let state = ConnectionStateFile::default();
        assert_eq!(state.schema_version, 1);
        assert_eq!(state.desired_state, DesiredState::Disconnected);
        assert_eq!(state.config, None);
        assert_eq!(state.retry_count, 0);
    }

    #[test]
    fn test_state_file_roundtrip() {
        let mut temp_file = NamedTempFile::new().unwrap();

        let state = ConnectionStateFile {
            schema_version: 1,
            desired_state: DesiredState::Connected,
            config: Some("[Interface]\nAddress = 10.0.0.2/32\n".to_string()),
            vpn_ip: Some("10.0.0.2".to_string()),
            server_endpoint: Some("1.2.3.4:51820".to_string()),
            last_connected_at: Some("1706600000".to_string()),
            last_updated_at: "1706600100".to_string(),
            retry_count: 5,
        };

        // Write state to temp file
        let json = serde_json::to_string_pretty(&state).unwrap();
        temp_file.write_all(json.as_bytes()).unwrap();
        temp_file.flush().unwrap();

        // Read it back
        let contents = std::fs::read_to_string(temp_file.path()).unwrap();
        let loaded: ConnectionStateFile = serde_json::from_str(&contents).unwrap();

        assert_eq!(loaded.desired_state, DesiredState::Connected);
        assert_eq!(loaded.config, state.config);
        assert_eq!(loaded.vpn_ip, state.vpn_ip);
        assert_eq!(loaded.retry_count, 5);
    }

    #[test]
    fn test_get_state_dir() {
        let dir = get_state_dir();

        #[cfg(target_os = "windows")]
        assert_eq!(dir, PathBuf::from(r"C:\ProgramData\SecureGuard"));

        #[cfg(not(target_os = "windows"))]
        assert_eq!(dir, PathBuf::from("/var/lib/secureguard"));
    }

    #[test]
    fn test_get_state_file_path() {
        let path = get_state_file_path();

        #[cfg(target_os = "windows")]
        assert_eq!(path, PathBuf::from(r"C:\ProgramData\SecureGuard\connection-state.json"));

        #[cfg(not(target_os = "windows"))]
        assert_eq!(path, PathBuf::from("/var/lib/secureguard/connection-state.json"));
    }

    #[test]
    fn test_corrupted_json_returns_none() {
        // Create a temp file with invalid JSON
        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(b"{ invalid json without closing brace").unwrap();
        temp_file.flush().unwrap();

        // Read the corrupted content - simulate what load_connection_state does
        let contents = std::fs::read_to_string(temp_file.path()).unwrap();
        let result: Result<ConnectionStateFile, _> = serde_json::from_str(&contents);

        // Should fail to parse
        assert!(result.is_err());
    }

    #[test]
    fn test_partial_json_returns_none() {
        // Test with JSON that's missing required fields
        let partial_json = r#"{"schema_version": 1}"#;
        let result: Result<ConnectionStateFile, _> = serde_json::from_str(partial_json);

        // Should fail because last_updated_at is required
        assert!(result.is_err());
    }

    #[test]
    fn test_empty_file_returns_none() {
        let mut temp_file = NamedTempFile::new().unwrap();
        temp_file.write_all(b"").unwrap();
        temp_file.flush().unwrap();

        let contents = std::fs::read_to_string(temp_file.path()).unwrap();
        let result: Result<ConnectionStateFile, _> = serde_json::from_str(&contents);

        // Empty string should fail to parse
        assert!(result.is_err());
    }
}
