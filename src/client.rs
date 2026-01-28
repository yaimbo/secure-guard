//! WireGuard client orchestration
//!
//! Main event loop that coordinates:
//! - TUN device read/write
//! - UDP socket communication
//! - Handshake initiation and response processing
//! - Keepalive timers
//! - Automatic rekey

use std::net::SocketAddr;
use std::time::Duration;

use tokio::net::UdpSocket;
use tokio::time::{interval, Interval};

use crate::config::WireGuardConfig;
use crate::error::{NetworkError, ProtocolError, SecureGuardError};
use crate::protocol::{
    CookieReply, CookieState, HandshakeResponse, InitiatorHandshake,
    MessageType, Session, SessionManager, TransportHeader,
};
use crate::protocol::messages::get_message_type;
use crate::protocol::session::generate_sender_index;
use crate::tunnel::{RouteManager, TunDevice};

/// Initial retry delay for connection
const INITIAL_RETRY_DELAY: Duration = Duration::from_secs(1);

/// Maximum retry delay
const MAX_RETRY_DELAY: Duration = Duration::from_secs(60);

/// Handshake timeout
const HANDSHAKE_TIMEOUT: Duration = Duration::from_secs(5);

/// Buffer size for packets
const BUFFER_SIZE: usize = 65535;

/// Result of processing a handshake packet
enum HandshakeResult {
    /// Handshake completed successfully
    Complete,
    /// Got a cookie, need to retry
    NeedRetry,
}

/// WireGuard client
pub struct WireGuardClient {
    /// Configuration
    config: WireGuardConfig,
    /// UDP socket for WireGuard traffic
    socket: UdpSocket,
    /// TUN device for IP traffic
    tun: TunDevice,
    /// Route manager
    routes: RouteManager,
    /// Session manager
    sessions: SessionManager,
    /// Cookie state for DoS protection
    cookie_state: CookieState,
    /// Current handshake state (if in progress)
    pending_handshake: Option<InitiatorHandshake>,
    /// Last MAC1 we sent (needed for cookie processing)
    last_mac1: [u8; 16],
    /// Peer endpoint
    peer_endpoint: SocketAddr,
    /// Keepalive interval
    keepalive_interval: Option<Duration>,
}

impl WireGuardClient {
    /// Create a new WireGuard client
    pub async fn new(config: WireGuardConfig) -> Result<Self, SecureGuardError> {
        // Parse our interface address
        let our_address = config.interface.address
            .first()
            .ok_or_else(|| SecureGuardError::Config(crate::error::ConfigError::MissingField {
                field: "Address".to_string(),
            }))?;

        // Create TUN device
        let tun = TunDevice::create(
            our_address.addr(),
            our_address.prefix_len(),
            config.interface.mtu.unwrap_or(1420),
        ).await?;

        // Create route manager
        let routes = RouteManager::new(tun.name().to_string());

        // Bind UDP socket
        // Use 0.0.0.0:0 to let the OS choose a port
        let socket = UdpSocket::bind("0.0.0.0:0").await
            .map_err(|e| NetworkError::BindFailed {
                addr: "0.0.0.0:0".to_string(),
                reason: e.to_string(),
            })?;

        // Get peer endpoint
        let peer = config.peers.first()
            .ok_or_else(|| SecureGuardError::Config(crate::error::ConfigError::MissingField {
                field: "Peer".to_string(),
            }))?;

        let peer_endpoint = peer.endpoint
            .ok_or_else(|| SecureGuardError::Config(crate::error::ConfigError::MissingField {
                field: "Endpoint".to_string(),
            }))?;

        // Keepalive interval
        let keepalive_interval = peer.persistent_keepalive
            .map(|secs| Duration::from_secs(secs as u64));

        Ok(Self {
            config,
            socket,
            tun,
            routes,
            sessions: SessionManager::new(),
            cookie_state: CookieState::new(),
            pending_handshake: None,
            last_mac1: [0u8; 16],
            peer_endpoint,
            keepalive_interval,
        })
    }

    /// Run the client (main event loop)
    pub async fn run(&mut self) -> Result<(), SecureGuardError> {
        // Connect with retry (handshake must complete BEFORE setting up routes,
        // otherwise the VPN endpoint gets routed through the non-existent tunnel)
        self.connect_with_retry().await?;

        // Set up routes for allowed IPs AFTER handshake succeeds
        self.setup_routes().await?;

        // Main event loop
        self.event_loop().await
    }

    /// Set up routes for peer's allowed IPs
    async fn setup_routes(&mut self) -> Result<(), SecureGuardError> {
        let peer = &self.config.peers[0];

        // CRITICAL: First add a route for the VPN endpoint to bypass the tunnel
        // This prevents a routing loop where encrypted packets get re-routed through the tunnel
        if let std::net::SocketAddr::V4(v4_addr) = self.peer_endpoint {
            let endpoint_ip = *v4_addr.ip();
            if let Err(e) = self.routes.add_endpoint_bypass(endpoint_ip).await {
                tracing::warn!("Failed to add endpoint bypass route: {}", e);
            }
        }

        for network in &peer.allowed_ips {
            // Convert IpNet to Ipv4Net (we only support IPv4 for now)
            if let ipnet::IpNet::V4(v4net) = network {
                if let Err(e) = self.routes.add_route(*v4net).await {
                    tracing::warn!("Failed to add route for {}: {}", network, e);
                    // Continue with other routes
                }
            }
        }

        Ok(())
    }

    /// Connect with automatic retry and exponential backoff
    async fn connect_with_retry(&mut self) -> Result<(), SecureGuardError> {
        let mut delay = INITIAL_RETRY_DELAY;
        let mut attempts = 0u32;

        loop {
            attempts += 1;
            tracing::info!("Connection attempt {}...", attempts);

            match self.perform_handshake().await {
                Ok(_) => {
                    tracing::info!("Handshake complete! Session established.");
                    return Ok(());
                }
                Err(e) => {
                    tracing::warn!("Handshake failed: {}. Retrying in {:?}...", e, delay);
                    tokio::time::sleep(delay).await;
                    delay = (delay * 2).min(MAX_RETRY_DELAY);
                }
            }
        }
    }

    /// Perform the WireGuard handshake
    async fn perform_handshake(&mut self) -> Result<(), SecureGuardError> {
        // Loop to handle cookie retry without recursion
        loop {
            let peer = &self.config.peers[0];

            // Create handshake initiator
            let sender_index = generate_sender_index();
            let mut handshake = InitiatorHandshake::new(
                self.config.interface.private_key,
                peer.public_key,
                self.config.interface.preshared_key,
                sender_index,
            );

            // Get cookie if available
            let cookie = self.cookie_state.get_cookie();

            // Create initiation message
            let init_msg = handshake.create_initiation(cookie)?;
            self.last_mac1 = init_msg.mac1;

            // Store handshake state
            self.pending_handshake = Some(handshake);
            self.sessions.start_handshake(sender_index);

            // Send initiation
            let init_bytes = init_msg.to_bytes();
            self.socket.send_to(&init_bytes, self.peer_endpoint).await
                .map_err(|e| NetworkError::SendFailed {
                    reason: e.to_string(),
                })?;

            // Wait for response with timeout
            let mut buf = [0u8; BUFFER_SIZE];
            let response = tokio::time::timeout(
                HANDSHAKE_TIMEOUT,
                self.socket.recv_from(&mut buf),
            ).await
                .map_err(|_| ProtocolError::HandshakeTimeout { seconds: HANDSHAKE_TIMEOUT.as_secs() })?
                .map_err(|e| NetworkError::ReceiveFailed { reason: e.to_string() })?;

            let (len, from) = response;
            let packet = &buf[..len];

            // Process response - returns true if we need to retry (got cookie)
            match self.process_handshake_packet(packet, from).await? {
                HandshakeResult::Complete => return Ok(()),
                HandshakeResult::NeedRetry => {
                    tracing::info!("Received cookie, retrying handshake...");
                    continue;
                }
            }
        }
    }

    /// Process a handshake packet (response or cookie reply)
    async fn process_handshake_packet(
        &mut self,
        packet: &[u8],
        from: SocketAddr,
    ) -> Result<HandshakeResult, SecureGuardError> {
        let msg_type = get_message_type(packet)?;

        match msg_type {
            MessageType::HandshakeResponse => {
                let response = HandshakeResponse::from_bytes(packet)?;

                // Verify MAC1
                crate::protocol::handshake::verify_response_mac1(
                    packet,
                    &crate::crypto::x25519::public_key(&self.config.interface.private_key),
                )?;

                // Process with pending handshake
                let handshake = self.pending_handshake.take()
                    .ok_or(ProtocolError::NoSession)?;

                let mut handshake = handshake;
                let result = handshake.process_response(&response)?;

                // Create session
                let session = Session::new(
                    result.local_index,
                    result.remote_index,
                    result.sending_key,
                    result.receiving_key,
                    from,
                );

                self.sessions.establish_session(session);
                self.cookie_state.clear(); // Clear cookie after successful handshake

                Ok(HandshakeResult::Complete)
            }
            MessageType::CookieReply => {
                let reply = CookieReply::from_bytes(packet)?;

                // Process cookie
                self.cookie_state.process_cookie_reply(
                    &reply,
                    &self.last_mac1,
                    &self.config.peers[0].public_key,
                )?;

                Ok(HandshakeResult::NeedRetry)
            }
            _ => {
                Err(ProtocolError::InvalidMessageType {
                    msg_type: packet[0],
                }.into())
            }
        }
    }

    /// Main event loop
    async fn event_loop(&mut self) -> Result<(), SecureGuardError> {
        let mut tun_buf = [0u8; BUFFER_SIZE];
        let mut udp_buf = [0u8; BUFFER_SIZE];

        // Keepalive interval
        let mut keepalive_timer: Option<Interval> = self.keepalive_interval
            .map(|d| interval(d));

        // Rekey check interval (every 10 seconds)
        let mut rekey_check = interval(Duration::from_secs(10));

        tracing::info!("Entering main event loop...");

        loop {
            tokio::select! {
                // Read from TUN -> encrypt -> send via UDP
                result = self.tun.read(&mut tun_buf) => {
                    match result {
                        Ok(len) => {
                            if let Err(e) = self.handle_tun_packet(&tun_buf[..len]).await {
                                tracing::warn!("Error handling TUN packet: {}", e);
                            }
                        }
                        Err(e) => {
                            tracing::error!("TUN read error: {}", e);
                        }
                    }
                }

                // Read from UDP -> process incoming packet
                result = self.socket.recv_from(&mut udp_buf) => {
                    match result {
                        Ok((len, from)) => {
                            if let Err(e) = self.handle_udp_packet(&udp_buf[..len], from).await {
                                tracing::trace!("Error handling UDP packet: {}", e);
                            }
                        }
                        Err(e) => {
                            tracing::error!("UDP recv error: {}", e);
                        }
                    }
                }

                // Keepalive timer
                _ = async {
                    if let Some(ref mut timer) = keepalive_timer {
                        timer.tick().await
                    } else {
                        std::future::pending::<tokio::time::Instant>().await
                    }
                } => {
                    if let Err(e) = self.send_keepalive().await {
                        tracing::warn!("Keepalive error: {}", e);
                    }
                }

                // Rekey check
                _ = rekey_check.tick() => {
                    if self.sessions.needs_rekey() {
                        tracing::info!("Session needs rekey, initiating new handshake...");
                        if let Err(e) = self.perform_handshake().await {
                            tracing::warn!("Rekey handshake failed: {}", e);
                        }
                    }
                }
            }
        }
    }

    /// Handle a packet from the TUN device (outgoing traffic)
    async fn handle_tun_packet(&mut self, packet: &[u8]) -> Result<(), SecureGuardError> {
        // Get current session
        let session = self.sessions.current_mut()
            .ok_or(ProtocolError::NoSession)?;

        // Encrypt and send
        let encrypted = session.transport.encrypt(session.remote_index, packet)?;
        session.mark_sent();

        self.socket.send_to(&encrypted, session.endpoint).await
            .map_err(|e| NetworkError::SendFailed {
                reason: e.to_string(),
            })?;

        Ok(())
    }

    /// Handle an incoming UDP packet
    async fn handle_udp_packet(
        &mut self,
        packet: &[u8],
        from: SocketAddr,
    ) -> Result<(), SecureGuardError> {
        if packet.is_empty() {
            return Ok(());
        }

        let msg_type = get_message_type(packet)?;

        match msg_type {
            MessageType::TransportData => {
                self.handle_transport_packet(packet, from).await
            }
            MessageType::HandshakeResponse => {
                // Process handshake response during event loop
                match self.process_handshake_packet(packet, from).await? {
                    HandshakeResult::Complete => {
                        tracing::info!("Handshake complete during event loop");
                        Ok(())
                    }
                    HandshakeResult::NeedRetry => {
                        // Got cookie during event loop - start new handshake
                        tracing::info!("Received cookie during event loop, will retry on next rekey");
                        Ok(())
                    }
                }
            }
            MessageType::CookieReply => {
                let reply = CookieReply::from_bytes(packet)?;
                self.cookie_state.process_cookie_reply(
                    &reply,
                    &self.last_mac1,
                    &self.config.peers[0].public_key,
                )?;
                tracing::info!("Received cookie reply");
                Ok(())
            }
            MessageType::HandshakeInitiation => {
                // We're a client, ignore initiations
                Ok(())
            }
        }
    }

    /// Handle an incoming transport data packet
    async fn handle_transport_packet(
        &mut self,
        packet: &[u8],
        from: SocketAddr,
    ) -> Result<(), SecureGuardError> {
        let header = TransportHeader::from_bytes(packet)?;

        // Find session by receiver index
        let session = self.sessions.find_by_index(header.receiver_index)
            .ok_or(ProtocolError::InvalidSenderIndex {
                index: header.receiver_index,
            })?;

        // Decrypt
        let plaintext = session.transport.decrypt(packet)?;
        session.mark_received();

        // Update endpoint if changed (roaming)
        if session.endpoint != from {
            tracing::info!("Peer endpoint changed from {} to {}", session.endpoint, from);
            session.endpoint = from;
        }

        // Write decrypted IP packet to TUN
        if !plaintext.is_empty() {
            self.tun.write(&plaintext).await?;
        }

        Ok(())
    }

    /// Send a keepalive packet (empty encrypted packet)
    async fn send_keepalive(&mut self) -> Result<(), SecureGuardError> {
        let session = self.sessions.current_mut()
            .ok_or(ProtocolError::NoSession)?;

        // Check if we actually need to send (no recent traffic)
        if let Some(keepalive_interval) = self.keepalive_interval {
            if !session.needs_keepalive(keepalive_interval) {
                return Ok(());
            }
        }

        // Send empty packet
        let encrypted = session.transport.encrypt(session.remote_index, &[])?;
        session.mark_sent();

        self.socket.send_to(&encrypted, session.endpoint).await
            .map_err(|e| NetworkError::SendFailed {
                reason: e.to_string(),
            })?;

        Ok(())
    }

    /// Clean up routes on shutdown
    pub async fn cleanup(&mut self) -> Result<(), SecureGuardError> {
        tracing::info!("Cleaning up routes...");
        self.routes.cleanup().await?;
        tracing::info!("Cleanup complete");
        Ok(())
    }
}
