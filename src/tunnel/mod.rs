//! TUN device abstraction layer
//!
//! Provides cross-platform TUN device support using the tun-rs crate.
//! Supports macOS (utun), Linux (/dev/net/tun), and Windows (Wintun).

use std::net::Ipv4Addr;
use std::ops::Deref;
use std::path::PathBuf;
use std::process::Command as StdCommand;

use ipnet::Ipv4Net;
use serde::{Deserialize, Serialize};
use tokio::process::Command;
use tun_rs::{AsyncDevice, DeviceBuilder};

use crate::error::{SecureGuardError, TunnelError};

/// Persistent state for route cleanup after crashes
#[derive(Debug, Clone, Serialize, Deserialize)]
pub struct RouteState {
    /// Interface name (e.g., "utun5", "tun0", "SecureGuard")
    pub interface: String,
    /// Interface index (Windows only, for precise route deletion)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub interface_index: Option<u32>,
    /// VPN endpoint IP (for bypass route cleanup)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub endpoint_bypass: Option<String>,
    /// Default gateway (for endpoint bypass cleanup)
    #[serde(skip_serializing_if = "Option::is_none")]
    pub default_gateway: Option<String>,
    /// Routes added through the tunnel (CIDR notation)
    pub routes: Vec<String>,
    /// Timestamp when state was saved
    pub timestamp: String,
}

/// Get the platform-specific path for the route state file
fn get_state_file_path() -> PathBuf {
    #[cfg(target_os = "windows")]
    {
        let path = PathBuf::from(r"C:\ProgramData\SecureGuard");
        // Create directory if needed (ignore errors, will fail on save if needed)
        let _ = std::fs::create_dir_all(&path);
        path.join("routes.json")
    }

    #[cfg(not(target_os = "windows"))]
    {
        PathBuf::from("/var/run/secureguard_routes.json")
    }
}

/// Save the current route state to persistent storage
fn save_route_state(state: &RouteState) -> Result<(), std::io::Error> {
    let path = get_state_file_path();
    let json = serde_json::to_string_pretty(state)
        .map_err(|e| std::io::Error::new(std::io::ErrorKind::InvalidData, e))?;
    std::fs::write(&path, json)?;
    tracing::debug!("Saved route state to {:?}", path);
    Ok(())
}

/// Load route state from persistent storage (if exists)
fn load_route_state() -> Option<RouteState> {
    let path = get_state_file_path();
    match std::fs::read_to_string(&path) {
        Ok(json) => {
            match serde_json::from_str(&json) {
                Ok(state) => {
                    tracing::info!("Found route state file at {:?}", path);
                    Some(state)
                }
                Err(e) => {
                    tracing::warn!("Failed to parse route state file: {}", e);
                    None
                }
            }
        }
        Err(_) => None, // File doesn't exist, that's fine
    }
}

/// Delete the route state file (called on clean exit)
fn delete_route_state() {
    let path = get_state_file_path();
    if let Err(e) = std::fs::remove_file(&path) {
        if e.kind() != std::io::ErrorKind::NotFound {
            tracing::warn!("Failed to delete route state file: {}", e);
        }
    } else {
        tracing::debug!("Deleted route state file");
    }
}

/// Check if an interface exists
fn interface_exists(interface: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        match StdCommand::new("ifconfig").args(["-l"]).output() {
            Ok(output) => {
                let list = String::from_utf8_lossy(&output.stdout);
                list.split_whitespace().any(|s| s == interface)
            }
            Err(_) => false,
        }
    }

    #[cfg(target_os = "linux")]
    {
        match StdCommand::new("ip").args(["link", "show", interface]).output() {
            Ok(output) => output.status.success(),
            Err(_) => false,
        }
    }

    #[cfg(target_os = "windows")]
    {
        match StdCommand::new("powershell")
            .args(["-Command", &format!("Get-NetAdapter -Name '{}' -ErrorAction SilentlyContinue", interface)])
            .output()
        {
            Ok(output) => !String::from_utf8_lossy(&output.stdout).trim().is_empty(),
            Err(_) => false,
        }
    }
}

/// Clean up routes from a previous crashed session using the state file.
/// This is the safe replacement for the old netstat-parsing approach.
pub fn cleanup_from_state_file() {
    let state = match load_route_state() {
        Some(s) => s,
        None => {
            tracing::debug!("No route state file found - no cleanup needed");
            return;
        }
    };

    tracing::info!(
        "Found orphaned route state from {} (interface: {})",
        state.timestamp,
        state.interface
    );

    // Safety check: if the interface still exists, skip cleanup
    // (another instance might be starting up)
    if interface_exists(&state.interface) {
        tracing::warn!(
            "Interface {} still exists - skipping cleanup (another session may be active)",
            state.interface
        );
        return;
    }

    tracing::info!("Interface {} no longer exists - cleaning up {} orphaned routes",
        state.interface,
        state.routes.len()
    );

    let mut cleaned = 0;
    let mut failed = 0;

    // Clean up regular routes
    for route in &state.routes {
        if cleanup_single_route(route, &state.interface, state.interface_index) {
            cleaned += 1;
        } else {
            failed += 1;
        }
    }

    // Clean up endpoint bypass route if present
    if let Some(ref endpoint) = state.endpoint_bypass {
        if let Some(ref gateway) = state.default_gateway {
            if cleanup_endpoint_bypass(endpoint, gateway) {
                tracing::debug!("Cleaned up endpoint bypass route for {}", endpoint);
            }
        }
    }

    // Delete the state file after cleanup
    delete_route_state();

    tracing::info!(
        "Route cleanup complete: {} removed, {} failed",
        cleaned,
        failed
    );
}

/// Clean up a single route (platform-specific)
fn cleanup_single_route(route: &str, interface: &str, _interface_index: Option<u32>) -> bool {
    #[cfg(target_os = "macos")]
    {
        // Use -interface to target the specific route
        let result = StdCommand::new("route")
            .args(["-n", "delete", "-net", route, "-interface", interface])
            .output();

        match result {
            Ok(output) => {
                if output.status.success() {
                    tracing::debug!("Removed orphaned route: {} via {}", route, interface);
                    true
                } else {
                    // Try without -interface as fallback (route might have been cleaned by system)
                    let _ = StdCommand::new("route")
                        .args(["-n", "delete", "-net", route])
                        .output();
                    false
                }
            }
            Err(e) => {
                tracing::trace!("Failed to remove route {}: {}", route, e);
                false
            }
        }
    }

    #[cfg(target_os = "linux")]
    {
        let result = StdCommand::new("ip")
            .args(["route", "del", route, "dev", interface])
            .output();

        match result {
            Ok(output) => {
                if output.status.success() {
                    tracing::debug!("Removed orphaned route: {} via {}", route, interface);
                    true
                } else {
                    false
                }
            }
            Err(e) => {
                tracing::trace!("Failed to remove route {}: {}", route, e);
                false
            }
        }
    }

    #[cfg(target_os = "windows")]
    {
        // On Windows, use interface index if available for precision
        let result = if let Some(idx) = _interface_index {
            StdCommand::new("route")
                .args(["delete", route, &format!("IF {}", idx)])
                .output()
        } else {
            StdCommand::new("route")
                .args(["delete", route])
                .output()
        };

        match result {
            Ok(output) => {
                if output.status.success() {
                    tracing::debug!("Removed orphaned route: {}", route);
                    true
                } else {
                    // Try PowerShell as fallback
                    let ps_result = if let Some(idx) = _interface_index {
                        StdCommand::new("powershell")
                            .args(["-Command", &format!(
                                "Remove-NetRoute -DestinationPrefix '{}' -InterfaceIndex {} -Confirm:$false -ErrorAction SilentlyContinue",
                                route, idx
                            )])
                            .output()
                    } else {
                        StdCommand::new("powershell")
                            .args(["-Command", &format!(
                                "Remove-NetRoute -DestinationPrefix '{}' -Confirm:$false -ErrorAction SilentlyContinue",
                                route
                            )])
                            .output()
                    };
                    ps_result.map(|o| o.status.success()).unwrap_or(false)
                }
            }
            Err(e) => {
                tracing::trace!("Failed to remove route {}: {}", route, e);
                false
            }
        }
    }
}

/// Clean up the endpoint bypass route
fn cleanup_endpoint_bypass(endpoint: &str, gateway: &str) -> bool {
    #[cfg(target_os = "macos")]
    {
        let result = StdCommand::new("route")
            .args(["-n", "delete", "-host", endpoint, gateway])
            .output();
        result.map(|o| o.status.success()).unwrap_or(false)
    }

    #[cfg(target_os = "linux")]
    {
        let result = StdCommand::new("ip")
            .args(["route", "del", &format!("{}/32", endpoint), "via", gateway])
            .output();
        result.map(|o| o.status.success()).unwrap_or(false)
    }

    #[cfg(target_os = "windows")]
    {
        let result = StdCommand::new("route")
            .args(["delete", endpoint, "mask", "255.255.255.255", gateway])
            .output();
        result.map(|o| o.status.success()).unwrap_or(false)
    }
}

/// Get the current default gateway (used for state file)
fn get_default_gateway() -> Option<String> {
    #[cfg(target_os = "macos")]
    {
        let output = StdCommand::new("route")
            .args(["-n", "get", "default"])
            .output()
            .ok()?;

        let output_str = String::from_utf8_lossy(&output.stdout);
        output_str
            .lines()
            .find(|line| line.contains("gateway:"))
            .and_then(|line| line.split(':').nth(1))
            .map(|s| s.trim().to_string())
    }

    #[cfg(target_os = "linux")]
    {
        let output = StdCommand::new("ip")
            .args(["route", "show", "default"])
            .output()
            .ok()?;

        let output_str = String::from_utf8_lossy(&output.stdout);
        output_str
            .split_whitespace()
            .skip_while(|&s| s != "via")
            .nth(1)
            .map(|s| s.to_string())
    }

    #[cfg(target_os = "windows")]
    {
        let output = StdCommand::new("powershell")
            .args(["-Command", "Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1 -ExpandProperty NextHop"])
            .output()
            .ok()?;

        let gateway = String::from_utf8_lossy(&output.stdout).trim().to_string();
        if gateway.is_empty() { None } else { Some(gateway) }
    }
}

/// Get the interface index (Windows only)
#[cfg(target_os = "windows")]
fn get_interface_index(interface: &str) -> Option<u32> {
    let output = StdCommand::new("powershell")
        .args(["-Command", &format!(
            "(Get-NetAdapter -Name '{}' -ErrorAction SilentlyContinue).ifIndex",
            interface
        )])
        .output()
        .ok()?;

    String::from_utf8_lossy(&output.stdout)
        .trim()
        .parse()
        .ok()
}

/// Async TUN device wrapper
pub struct TunDevice {
    /// The underlying async TUN device
    device: AsyncDevice,
    /// Device name (e.g., "utun5", "tun0", "WireGuard")
    name: String,
}

impl TunDevice {
    /// Create a new TUN device with the given configuration
    pub async fn create(
        address: Ipv4Addr,
        prefix_len: u8,
        mtu: u16,
    ) -> Result<Self, SecureGuardError> {
        // Check for required privileges first
        check_privileges()?;

        let builder = DeviceBuilder::new();

        #[cfg(target_os = "windows")]
        {
            builder = builder.name("SecureGuard");
        }

        let device = builder
            .ipv4(address, prefix_len, None)
            .mtu(mtu)
            .build_async()
            .map_err(|e| TunnelError::CreateFailed {
                reason: e.to_string(),
            })?;

        // Get device name
        let name = device.deref().name()
            .map_err(|e| TunnelError::CreateFailed {
                reason: format!("Failed to get device name: {}", e),
            })?;

        tracing::info!("Created TUN device: {} with address {}/{}", name, address, prefix_len);

        Ok(Self {
            device,
            name,
        })
    }

    /// Get the device name
    pub fn name(&self) -> &str {
        &self.name
    }

    /// Read a packet from the TUN device
    pub async fn read(&self, buf: &mut [u8]) -> Result<usize, SecureGuardError> {
        self.device
            .recv(buf)
            .await
            .map_err(|e| TunnelError::ReadFailed {
                reason: e.to_string(),
            }.into())
    }

    /// Write a packet to the TUN device
    pub async fn write(&self, packet: &[u8]) -> Result<usize, SecureGuardError> {
        self.device
            .send(packet)
            .await
            .map_err(|e| TunnelError::WriteFailed {
                reason: e.to_string(),
            }.into())
    }
}

/// Check for required privileges to create TUN devices
fn check_privileges() -> Result<(), SecureGuardError> {
    #[cfg(unix)]
    {
        // On Unix, we need root or CAP_NET_ADMIN
        if unsafe { libc::geteuid() } != 0 {
            // Check for CAP_NET_ADMIN on Linux
            #[cfg(target_os = "linux")]
            {
                // For now, just warn - the tun creation will fail with a clear error
                tracing::warn!("Running without root. TUN creation may fail.");
                tracing::warn!("Either run with sudo or grant CAP_NET_ADMIN:");
                tracing::warn!("  sudo setcap cap_net_admin=eip ./secureguard-poc");
            }

            #[cfg(target_os = "macos")]
            {
                return Err(TunnelError::InsufficientPrivileges {
                    message: "Root privileges required on macOS. Run with sudo.".to_string(),
                }.into());
            }
        }
    }

    #[cfg(target_os = "windows")]
    {
        if !is_elevated_windows() {
            return Err(TunnelError::InsufficientPrivileges {
                message: "Administrator privileges required on Windows.".to_string(),
            }.into());
        }
    }

    Ok(())
}

/// Check if running as Administrator on Windows
#[cfg(target_os = "windows")]
fn is_elevated_windows() -> bool {
    use std::mem::MaybeUninit;
    use std::ptr::null_mut;

    use winapi::um::handleapi::CloseHandle;
    use winapi::um::processthreadsapi::{GetCurrentProcess, OpenProcessToken};
    use winapi::um::securitybaseapi::GetTokenInformation;
    use winapi::um::winnt::{TokenElevation, HANDLE, TOKEN_ELEVATION, TOKEN_QUERY};

    unsafe {
        let mut token: HANDLE = null_mut();
        if OpenProcessToken(GetCurrentProcess(), TOKEN_QUERY, &mut token) == 0 {
            return false;
        }

        let mut elevation: MaybeUninit<TOKEN_ELEVATION> = MaybeUninit::uninit();
        let mut size: u32 = std::mem::size_of::<TOKEN_ELEVATION>() as u32;

        let result = GetTokenInformation(
            token,
            TokenElevation,
            elevation.as_mut_ptr() as *mut _,
            size,
            &mut size,
        );

        CloseHandle(token);

        if result == 0 {
            return false;
        }

        elevation.assume_init().TokenIsElevated != 0
    }
}

/// Route management for directing traffic through the tunnel
pub struct RouteManager {
    /// Device name for routing
    device_name: String,
    /// Routes that have been added
    added_routes: Vec<Ipv4Net>,
    /// Endpoint bypass route (needs separate cleanup)
    endpoint_bypass: Option<Ipv4Addr>,
    /// Default gateway (for state file)
    default_gateway: Option<String>,
    /// Interface index (Windows only)
    #[cfg(target_os = "windows")]
    interface_index: Option<u32>,
}

impl RouteManager {
    /// Create a new route manager
    pub fn new(device_name: String) -> Self {
        // Capture default gateway at creation time
        let default_gateway = get_default_gateway();

        #[cfg(target_os = "windows")]
        let interface_index = get_interface_index(&device_name);

        Self {
            device_name,
            added_routes: Vec::new(),
            endpoint_bypass: None,
            default_gateway,
            #[cfg(target_os = "windows")]
            interface_index,
        }
    }

    /// Clean up any stale routes from previous SecureGuard sessions.
    /// This should be called on startup before adding new routes.
    /// Uses the persistent state file approach for safe, deterministic cleanup.
    pub fn cleanup_stale_routes() {
        tracing::info!("Checking for stale routes from previous sessions...");
        cleanup_from_state_file();
    }

    /// Save current route state to persistent storage
    fn save_state(&self) {
        let state = RouteState {
            interface: self.device_name.clone(),
            #[cfg(target_os = "windows")]
            interface_index: self.interface_index,
            #[cfg(not(target_os = "windows"))]
            interface_index: None,
            endpoint_bypass: self.endpoint_bypass.map(|ip| ip.to_string()),
            default_gateway: self.default_gateway.clone(),
            routes: self.added_routes.iter().map(|r| r.to_string()).collect(),
            timestamp: std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .map(|d| d.as_secs().to_string())
                .unwrap_or_else(|_| "0".to_string()),
        };

        if let Err(e) = save_route_state(&state) {
            tracing::warn!("Failed to save route state: {} (routes will need manual cleanup on crash)", e);
        }
    }

    /// Add a bypass route for the VPN endpoint to go through the default gateway
    /// This prevents a routing loop where encrypted packets would be re-routed through the tunnel
    pub async fn add_endpoint_bypass(&mut self, endpoint: Ipv4Addr) -> Result<(), SecureGuardError> {
        add_endpoint_bypass_platform(endpoint).await?;
        self.endpoint_bypass = Some(endpoint);
        self.save_state();
        tracing::info!("Added endpoint bypass route for {}", endpoint);
        Ok(())
    }

    /// Add a route for the given network
    pub async fn add_route(&mut self, network: Ipv4Net) -> Result<(), SecureGuardError> {
        add_route_platform(&self.device_name, &network).await?;
        self.added_routes.push(network);
        self.save_state();
        tracing::info!("Added route: {} via {}", network, self.device_name);
        Ok(())
    }

    /// Remove a single route (for dynamic peer removal)
    pub async fn remove_route(&mut self, network: Ipv4Net) -> Result<(), SecureGuardError> {
        if let Err(e) = remove_route_platform(&self.device_name, &network).await {
            tracing::warn!("Failed to remove route {}: {}", network, e);
            return Err(e);
        }

        // Remove from tracked routes
        self.added_routes.retain(|r| r != &network);
        self.save_state();

        tracing::info!("Removed route: {} from {}", network, self.device_name);
        Ok(())
    }

    /// Remove all routes that were added
    pub async fn cleanup(&mut self) -> Result<(), SecureGuardError> {
        let mut errors = Vec::new();

        // Clean up endpoint bypass route first
        if let Some(endpoint) = self.endpoint_bypass.take() {
            if let Err(e) = remove_endpoint_bypass_platform(endpoint).await {
                tracing::warn!("Failed to remove endpoint bypass route: {}", e);
            } else {
                tracing::debug!("Removed endpoint bypass route for {}", endpoint);
            }
        }

        for network in self.added_routes.drain(..) {
            if let Err(e) = remove_route_platform(&self.device_name, &network).await {
                tracing::warn!("Failed to remove route {}: {}", network, e);
                errors.push((network, e));
            } else {
                tracing::debug!("Removed route: {}", network);
            }
        }

        // Delete state file on clean exit
        delete_route_state();

        if !errors.is_empty() {
            // Log but don't fail - best effort cleanup
            tracing::warn!("Some routes could not be removed");
        }

        Ok(())
    }

    /// Get the list of added routes
    pub fn routes(&self) -> &[Ipv4Net] {
        &self.added_routes
    }
}

/// Platform-specific route addition
async fn add_route_platform(device: &str, network: &Ipv4Net) -> Result<(), SecureGuardError> {
    #[cfg(target_os = "macos")]
    {
        let status = Command::new("route")
            .args(["-n", "add", "-net", &network.to_string(), "-interface", device])
            .status()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: format!("route command exited with {}", status),
            }.into());
        }
    }

    #[cfg(target_os = "linux")]
    {
        let status = Command::new("ip")
            .args(["route", "add", &network.to_string(), "dev", device])
            .status()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: format!("ip route command exited with {}", status),
            }.into());
        }
    }

    #[cfg(target_os = "windows")]
    {
        // Get interface index
        let output = Command::new("powershell")
            .args(["-Command", &format!(
                "(Get-NetAdapter -Name '{}').ifIndex",
                device
            )])
            .output()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        let if_index = String::from_utf8_lossy(&output.stdout)
            .trim()
            .to_string();

        let status = Command::new("netsh")
            .args([
                "interface", "ip", "add", "route",
                &network.to_string(),
                &if_index,
            ])
            .status()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteSetupFailed {
                network: network.to_string(),
                reason: format!("netsh command exited with {}", status),
            }.into());
        }
    }

    Ok(())
}

/// Platform-specific route removal
async fn remove_route_platform(_device: &str, network: &Ipv4Net) -> Result<(), SecureGuardError> {
    #[cfg(target_os = "macos")]
    {
        let status = Command::new("route")
            .args(["-n", "delete", "-net", &network.to_string()])
            .status()
            .await
            .map_err(|e| TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: format!("route command exited with {}", status),
            }.into());
        }
    }

    #[cfg(target_os = "linux")]
    {
        let status = Command::new("ip")
            .args(["route", "del", &network.to_string(), "dev", device])
            .status()
            .await
            .map_err(|e| TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: format!("ip route command exited with {}", status),
            }.into());
        }
    }

    #[cfg(target_os = "windows")]
    {
        let output = Command::new("powershell")
            .args(["-Command", &format!(
                "(Get-NetAdapter -Name '{}').ifIndex",
                device
            )])
            .output()
            .await
            .map_err(|e| TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        let if_index = String::from_utf8_lossy(&output.stdout)
            .trim()
            .to_string();

        let status = Command::new("netsh")
            .args([
                "interface", "ip", "delete", "route",
                &network.to_string(),
                &if_index,
            ])
            .status()
            .await
            .map_err(|e| TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteCleanupFailed {
                network: network.to_string(),
                reason: format!("netsh command exited with {}", status),
            }.into());
        }
    }

    Ok(())
}

/// Add a route for the VPN endpoint to bypass the tunnel (go through default gateway)
async fn add_endpoint_bypass_platform(endpoint: Ipv4Addr) -> Result<(), SecureGuardError> {
    let endpoint_str = endpoint.to_string();

    #[cfg(target_os = "macos")]
    {
        // Get default gateway
        let output = Command::new("route")
            .args(["-n", "get", "default"])
            .output()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: format!("Failed to get default gateway: {}", e),
            })?;

        let output_str = String::from_utf8_lossy(&output.stdout);
        let gateway = output_str
            .lines()
            .find(|line| line.contains("gateway:"))
            .and_then(|line| line.split(':').nth(1))
            .map(|s| s.trim().to_string())
            .ok_or_else(|| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: "Could not parse default gateway".to_string(),
            })?;

        // Add specific route for endpoint through default gateway
        let status = Command::new("route")
            .args(["-n", "add", "-host", &endpoint_str, &gateway])
            .status()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteSetupFailed {
                network: endpoint_str,
                reason: format!("route add command failed"),
            }.into());
        }
    }

    #[cfg(target_os = "linux")]
    {
        // Get default gateway
        let output = Command::new("ip")
            .args(["route", "show", "default"])
            .output()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: format!("Failed to get default gateway: {}", e),
            })?;

        let output_str = String::from_utf8_lossy(&output.stdout);
        // Parse "default via X.X.X.X dev ethX"
        let gateway = output_str
            .split_whitespace()
            .skip_while(|&s| s != "via")
            .nth(1)
            .map(|s| s.to_string())
            .ok_or_else(|| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: "Could not parse default gateway".to_string(),
            })?;

        let status = Command::new("ip")
            .args(["route", "add", &endpoint_str, "via", &gateway])
            .status()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteSetupFailed {
                network: endpoint_str,
                reason: format!("ip route add command failed"),
            }.into());
        }
    }

    #[cfg(target_os = "windows")]
    {
        // Get default gateway from route table
        let output = Command::new("powershell")
            .args(["-Command", "Get-NetRoute -DestinationPrefix '0.0.0.0/0' | Select-Object -First 1 -ExpandProperty NextHop"])
            .output()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: format!("Failed to get default gateway: {}", e),
            })?;

        let gateway = String::from_utf8_lossy(&output.stdout).trim().to_string();

        let status = Command::new("route")
            .args(["add", &endpoint_str, "mask", "255.255.255.255", &gateway])
            .status()
            .await
            .map_err(|e| TunnelError::RouteSetupFailed {
                network: endpoint_str.clone(),
                reason: e.to_string(),
            })?;

        if !status.success() {
            return Err(TunnelError::RouteSetupFailed {
                network: endpoint_str,
                reason: format!("route add command failed"),
            }.into());
        }
    }

    Ok(())
}

/// Remove the VPN endpoint bypass route
async fn remove_endpoint_bypass_platform(endpoint: Ipv4Addr) -> Result<(), SecureGuardError> {
    let endpoint_str = endpoint.to_string();

    #[cfg(target_os = "macos")]
    {
        let _ = Command::new("route")
            .args(["-n", "delete", "-host", &endpoint_str])
            .status()
            .await;
    }

    #[cfg(target_os = "linux")]
    {
        let _ = Command::new("ip")
            .args(["route", "del", &endpoint_str])
            .status()
            .await;
    }

    #[cfg(target_os = "windows")]
    {
        let _ = Command::new("route")
            .args(["delete", &endpoint_str])
            .status()
            .await;
    }

    Ok(())
}

// Old netstat-parsing cleanup functions have been removed.
// Route cleanup now uses the persistent state file approach via cleanup_from_state_file().

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::Write;
    use tempfile::NamedTempFile;

    #[test]
    fn test_route_state_serialization() {
        let state = RouteState {
            interface: "utun5".to_string(),
            interface_index: None,
            endpoint_bypass: Some("203.0.113.1".to_string()),
            default_gateway: Some("192.168.1.1".to_string()),
            routes: vec![
                "10.13.13.0/24".to_string(),
                "10.10.10.0/24".to_string(),
                "8.8.8.8/32".to_string(),
            ],
            timestamp: "1234567890".to_string(),
        };

        // Serialize
        let json = serde_json::to_string_pretty(&state).unwrap();
        assert!(json.contains("utun5"));
        assert!(json.contains("10.13.13.0/24"));
        assert!(json.contains("203.0.113.1"));

        // Deserialize
        let parsed: RouteState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.interface, "utun5");
        assert_eq!(parsed.routes.len(), 3);
        assert_eq!(parsed.endpoint_bypass, Some("203.0.113.1".to_string()));
    }

    #[test]
    fn test_route_state_without_optional_fields() {
        let state = RouteState {
            interface: "tun0".to_string(),
            interface_index: None,
            endpoint_bypass: None,
            default_gateway: None,
            routes: vec!["10.0.0.0/8".to_string()],
            timestamp: "0".to_string(),
        };

        let json = serde_json::to_string(&state).unwrap();
        // Optional None fields should not appear in JSON
        assert!(!json.contains("endpoint_bypass"));
        assert!(!json.contains("default_gateway"));
        assert!(!json.contains("interface_index"));

        // Should still deserialize correctly
        let parsed: RouteState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.endpoint_bypass, None);
    }

    #[test]
    fn test_route_state_with_windows_fields() {
        let state = RouteState {
            interface: "SecureGuard".to_string(),
            interface_index: Some(12),
            endpoint_bypass: Some("10.0.0.1".to_string()),
            default_gateway: Some("192.168.0.1".to_string()),
            routes: vec!["0.0.0.0/0".to_string()],
            timestamp: "9999999999".to_string(),
        };

        let json = serde_json::to_string_pretty(&state).unwrap();
        assert!(json.contains("\"interface_index\": 12"));

        let parsed: RouteState = serde_json::from_str(&json).unwrap();
        assert_eq!(parsed.interface_index, Some(12));
    }

    #[test]
    fn test_state_file_roundtrip() {
        // Create a temp file to simulate state file
        let mut temp_file = NamedTempFile::new().unwrap();

        let state = RouteState {
            interface: "utun99".to_string(),
            interface_index: None,
            endpoint_bypass: Some("1.2.3.4".to_string()),
            default_gateway: Some("192.168.1.1".to_string()),
            routes: vec!["10.0.0.0/8".to_string(), "172.16.0.0/12".to_string()],
            timestamp: "1706600000".to_string(),
        };

        // Write state to temp file
        let json = serde_json::to_string_pretty(&state).unwrap();
        temp_file.write_all(json.as_bytes()).unwrap();
        temp_file.flush().unwrap();

        // Read it back
        let contents = std::fs::read_to_string(temp_file.path()).unwrap();
        let loaded: RouteState = serde_json::from_str(&contents).unwrap();

        assert_eq!(loaded.interface, "utun99");
        assert_eq!(loaded.routes.len(), 2);
        assert_eq!(loaded.endpoint_bypass, Some("1.2.3.4".to_string()));
    }

    #[test]
    fn test_interface_exists_nonexistent() {
        // A clearly nonexistent interface should return false
        assert!(!interface_exists("utun99999"));
        assert!(!interface_exists("nonexistent_interface_xyz"));
    }

    #[test]
    fn test_interface_exists_loopback() {
        // lo0 (macOS) or lo (Linux) should exist
        #[cfg(target_os = "macos")]
        assert!(interface_exists("lo0"));

        #[cfg(target_os = "linux")]
        assert!(interface_exists("lo"));
    }
}
