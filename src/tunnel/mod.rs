//! TUN device abstraction layer
//!
//! Provides cross-platform TUN device support using the tun-rs crate.
//! Supports macOS (utun), Linux (/dev/net/tun), and Windows (Wintun).

use std::net::Ipv4Addr;
use std::ops::Deref;
use std::process::Command as StdCommand;

use ipnet::Ipv4Net;
use tokio::process::Command;
use tun_rs::{AsyncDevice, DeviceBuilder};

use crate::error::{SecureGuardError, TunnelError};

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
}

impl RouteManager {
    /// Create a new route manager
    pub fn new(device_name: String) -> Self {
        Self {
            device_name,
            added_routes: Vec::new(),
            endpoint_bypass: None,
        }
    }

    /// Clean up any stale routes from previous SecureGuard sessions.
    /// This should be called on startup before adding new routes.
    pub fn cleanup_stale_routes() {
        tracing::info!("Checking for stale routes from previous sessions...");

        #[cfg(target_os = "macos")]
        {
            cleanup_stale_routes_macos();
        }

        #[cfg(target_os = "linux")]
        {
            cleanup_stale_routes_linux();
        }

        #[cfg(target_os = "windows")]
        {
            cleanup_stale_routes_windows();
        }
    }

    /// Add a bypass route for the VPN endpoint to go through the default gateway
    /// This prevents a routing loop where encrypted packets would be re-routed through the tunnel
    pub async fn add_endpoint_bypass(&mut self, endpoint: Ipv4Addr) -> Result<(), SecureGuardError> {
        add_endpoint_bypass_platform(endpoint).await?;
        self.endpoint_bypass = Some(endpoint);
        tracing::info!("Added endpoint bypass route for {}", endpoint);
        Ok(())
    }

    /// Add a route for the given network
    pub async fn add_route(&mut self, network: Ipv4Net) -> Result<(), SecureGuardError> {
        add_route_platform(&self.device_name, &network).await?;
        self.added_routes.push(network);
        tracing::info!("Added route: {} via {}", network, self.device_name);
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

/// Clean up stale routes on macOS
/// ONLY removes routes pointing to utun devices that NO LONGER EXIST.
/// CRITICAL: Also skips routes if the destination is used by ANY active interface,
/// to avoid accidentally deleting working routes (e.g., default route through en0).
#[cfg(target_os = "macos")]
fn cleanup_stale_routes_macos() {
    use std::collections::HashSet;

    // Get list of active utun interfaces
    let active_utuns: HashSet<String> = match StdCommand::new("ifconfig")
        .args(["-l"])
        .output()
    {
        Ok(output) => {
            String::from_utf8_lossy(&output.stdout)
                .split_whitespace()
                .filter(|s| s.starts_with("utun"))
                .map(|s| s.to_string())
                .collect()
        }
        Err(e) => {
            tracing::warn!("Failed to list interfaces: {}", e);
            return;
        }
    };

    tracing::debug!("Active utun interfaces: {:?}", active_utuns);

    // Get routing table
    let routes_output = match StdCommand::new("netstat")
        .args(["-rn"])
        .output()
    {
        Ok(output) => String::from_utf8_lossy(&output.stdout).to_string(),
        Err(e) => {
            tracing::warn!("Failed to get routing table: {}", e);
            return;
        }
    };

    // STEP 1: Collect all destinations that are used by ACTIVE interfaces
    // This includes both active utun interfaces AND non-utun interfaces (en0, lo0, etc.)
    // We must NOT delete any route that shares a destination with a working interface
    let mut destinations_with_active_routes: HashSet<String> = HashSet::new();

    for line in routes_output.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 4 {
            continue;
        }

        let iface = parts.last().unwrap_or(&"");
        let destination = parts[0].to_string();

        // If this interface is active (exists), record that this destination has a working route
        // This includes: active utuns, AND any non-utun interface (en0, lo0, bridge, etc.)
        let is_active_utun = iface.starts_with("utun") && active_utuns.contains(*iface);
        let is_non_utun = !iface.starts_with("utun");

        if is_active_utun || is_non_utun {
            destinations_with_active_routes.insert(destination);
        }
    }

    // STEP 2: Find and delete orphaned routes (non-existent utun, destination not shared)
    let mut cleaned = 0;
    let mut skipped_shared = 0;
    let mut orphaned_interfaces: HashSet<String> = HashSet::new();

    for line in routes_output.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 4 {
            continue;
        }

        let iface = parts.last().unwrap_or(&"");
        if !iface.starts_with("utun") {
            continue;
        }

        // Skip if interface still exists
        if active_utuns.contains(*iface) {
            continue;
        }

        let destination = parts[0];

        // Skip localhost and link-local routes
        if destination == "127.0.0.1" || destination.starts_with("fe80") || destination == "::1" {
            continue;
        }

        // CRITICAL SAFETY CHECK: Skip if this destination has an active route through another interface
        // This prevents deleting e.g., "default" route which would kill internet
        if destinations_with_active_routes.contains(destination) {
            tracing::debug!(
                "Skipping orphaned route {} via {} - destination has active route through another interface",
                destination, iface
            );
            skipped_shared += 1;
            continue;
        }

        // Safe to delete - destination is ONLY used by the dead interface
        orphaned_interfaces.insert(iface.to_string());

        let is_host = parts.iter().any(|&f| f.contains('H'));
        let delete_args = if is_host {
            vec!["-n", "delete", "-host", destination]
        } else {
            vec!["-n", "delete", "-net", destination]
        };

        match StdCommand::new("route")
            .args(&delete_args)
            .output()
        {
            Ok(output) => {
                if output.status.success() {
                    cleaned += 1;
                    tracing::debug!("Removed orphaned route: {} (was via non-existent {})", destination, iface);
                }
            }
            Err(e) => {
                tracing::trace!("Failed to remove route {}: {}", destination, e);
            }
        }
    }

    if cleaned > 0 || skipped_shared > 0 {
        tracing::info!(
            "Route cleanup: removed {} orphaned, skipped {} shared destinations, interfaces: {:?}",
            cleaned,
            skipped_shared,
            orphaned_interfaces
        );
    } else {
        tracing::debug!("No orphaned routes found");
    }
}

/// Clean up stale routes on Linux
/// ONLY removes routes pointing to tun/wg devices that NO LONGER EXIST.
/// CRITICAL: Also skips routes if the destination is used by ANY active interface.
#[cfg(target_os = "linux")]
fn cleanup_stale_routes_linux() {
    use std::collections::HashSet;

    // Get list of ALL active network interfaces
    let active_interfaces: HashSet<String> = match StdCommand::new("ip")
        .args(["link", "show"])
        .output()
    {
        Ok(output) => {
            let out = String::from_utf8_lossy(&output.stdout);
            out.lines()
                .filter_map(|line| {
                    // Parse lines like "5: tun0: <...>" or "2: eth0: <...>"
                    if line.starts_with(char::is_numeric) || line.starts_with(' ') {
                        line.split(':').nth(1).map(|s| s.trim().to_string())
                    } else {
                        None
                    }
                })
                .collect()
        }
        Err(_) => HashSet::new(),
    };

    tracing::debug!("Active interfaces: {:?}", active_interfaces);

    // Get routing table
    let routes_output = match StdCommand::new("ip")
        .args(["route", "show"])
        .output()
    {
        Ok(output) => String::from_utf8_lossy(&output.stdout).to_string(),
        Err(e) => {
            tracing::warn!("Failed to get routing table: {}", e);
            return;
        }
    };

    // STEP 1: Collect destinations used by active interfaces
    let mut destinations_with_active_routes: HashSet<String> = HashSet::new();

    for line in routes_output.lines() {
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.is_empty() {
            continue;
        }

        let destination = parts[0].to_string();
        let dev_idx = parts.iter().position(|&s| s == "dev");

        if let Some(idx) = dev_idx {
            if let Some(dev) = parts.get(idx + 1) {
                // If interface is active, record this destination
                if active_interfaces.contains(*dev) {
                    destinations_with_active_routes.insert(destination);
                }
            }
        }
    }

    // STEP 2: Delete orphaned routes (dead interface, destination not shared)
    let mut cleaned = 0;
    let mut skipped_shared = 0;
    let mut orphaned_interfaces: HashSet<String> = HashSet::new();

    for line in routes_output.lines() {
        // Look for routes with "dev tunX" or "dev wg0" etc.
        if !line.contains(" dev tun") && !line.contains(" dev wg") {
            continue;
        }

        let parts: Vec<&str> = line.split_whitespace().collect();
        let dev_idx = parts.iter().position(|&s| s == "dev");

        if let Some(idx) = dev_idx {
            if let Some(dev) = parts.get(idx + 1) {
                // Skip if interface still exists
                if active_interfaces.contains(*dev) {
                    continue;
                }

                let destination = parts[0];

                // CRITICAL: Skip if destination has an active route
                if destinations_with_active_routes.contains(destination) {
                    tracing::debug!(
                        "Skipping orphaned route {} via {} - destination has active route",
                        destination, dev
                    );
                    skipped_shared += 1;
                    continue;
                }

                // Safe to delete
                orphaned_interfaces.insert(dev.to_string());

                match StdCommand::new("ip")
                    .args(["route", "del", destination])
                    .output()
                {
                    Ok(output) if output.status.success() => {
                        cleaned += 1;
                        tracing::debug!("Removed orphaned route: {} (was via non-existent {})", destination, dev);
                    }
                    _ => {}
                }
            }
        }
    }

    if cleaned > 0 || skipped_shared > 0 {
        tracing::info!(
            "Route cleanup: removed {} orphaned, skipped {} shared destinations, interfaces: {:?}",
            cleaned,
            skipped_shared,
            orphaned_interfaces
        );
    } else {
        tracing::debug!("No orphaned routes found");
    }
}

/// Clean up stale routes on Windows
/// ONLY removes routes pointing to interfaces that NO LONGER EXIST.
/// CRITICAL: Also skips routes if the destination is used by ANY active interface.
/// Windows typically cleans up routes automatically, so this is mostly a safety net.
#[cfg(target_os = "windows")]
fn cleanup_stale_routes_windows() {
    use std::collections::HashSet;

    // Get list of active network adapters
    let active_adapters: HashSet<String> = match StdCommand::new("powershell")
        .args(["-Command", "Get-NetAdapter | Select-Object -ExpandProperty Name"])
        .output()
    {
        Ok(output) => {
            String::from_utf8_lossy(&output.stdout)
                .lines()
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect()
        }
        Err(_) => return,
    };

    tracing::debug!("Active adapters: {:?}", active_adapters);

    // Get ALL routes to find destinations used by active interfaces
    let all_routes = match StdCommand::new("powershell")
        .args(["-Command", "Get-NetRoute | Select-Object DestinationPrefix, InterfaceAlias | ConvertTo-Csv -NoTypeInformation"])
        .output()
    {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(_) => return,
    };

    // STEP 1: Collect destinations used by active interfaces
    let mut destinations_with_active_routes: HashSet<String> = HashSet::new();

    for line in all_routes.lines().skip(1) {
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() < 2 {
            continue;
        }

        let destination = parts[0].trim_matches('"').trim().to_string();
        let interface = parts[1].trim_matches('"').trim();

        if active_adapters.contains(interface) {
            destinations_with_active_routes.insert(destination);
        }
    }

    // Get routes through WireGuard/SecureGuard interfaces
    let wg_routes = match StdCommand::new("powershell")
        .args(["-Command", "Get-NetRoute | Where-Object { $_.InterfaceAlias -like 'WireGuard*' -or $_.InterfaceAlias -like 'SecureGuard*' } | Select-Object DestinationPrefix, InterfaceAlias | ConvertTo-Csv -NoTypeInformation"])
        .output()
    {
        Ok(o) => String::from_utf8_lossy(&o.stdout).to_string(),
        Err(_) => return,
    };

    // STEP 2: Delete orphaned routes (dead interface, destination not shared)
    let mut cleaned = 0;
    let mut skipped_shared = 0;
    let mut orphaned_interfaces: HashSet<String> = HashSet::new();

    for line in wg_routes.lines().skip(1) {
        let parts: Vec<&str> = line.split(',').collect();
        if parts.len() < 2 {
            continue;
        }

        let destination = parts[0].trim_matches('"').trim();
        let interface = parts[1].trim_matches('"').trim();

        if destination.is_empty() || interface.is_empty() {
            continue;
        }

        // Skip if interface still exists
        if active_adapters.contains(interface) {
            continue;
        }

        // CRITICAL: Skip if destination has an active route
        if destinations_with_active_routes.contains(destination) {
            tracing::debug!(
                "Skipping orphaned route {} via {} - destination has active route",
                destination, interface
            );
            skipped_shared += 1;
            continue;
        }

        // Safe to delete
        orphaned_interfaces.insert(interface.to_string());

        match StdCommand::new("route")
            .args(["delete", destination])
            .output()
        {
            Ok(output) if output.status.success() => {
                cleaned += 1;
                tracing::debug!("Removed orphaned route: {} (was via non-existent {})", destination, interface);
            }
            _ => {}
        }
    }

    if cleaned > 0 || skipped_shared > 0 {
        tracing::info!(
            "Route cleanup: removed {} orphaned, skipped {} shared destinations, interfaces: {:?}",
            cleaned,
            skipped_shared,
            orphaned_interfaces
        );
    } else {
        tracing::debug!("No orphaned routes found");
    }
}
