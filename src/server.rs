//! WireGuard server orchestration
//!
//! Main event loop for server mode that handles:
//! - Listening on UDP port for incoming handshakes
//! - Processing handshake initiations from peers
//! - Managing multiple peer sessions
//! - Routing packets between TUN and UDP based on AllowedIPs

use std::net::{Ipv4Addr, SocketAddr};
use std::time::Duration;

use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use tokio::net::UdpSocket;
use tokio::time::{interval, Interval};

use crate::config::WireGuardConfig;
use crate::crypto::x25519;
use crate::error::{ConfigError, NetworkError, ProtocolError, SecureGuardError};
use crate::protocol::{
    verify_initiation_mac1, HandshakeInitiation, MessageType, PeerManager, ResponderHandshake,
    Session, TransportHeader,
};
use crate::protocol::messages::get_message_type;
use crate::protocol::session::generate_sender_index;
use crate::tunnel::{RouteManager, TunDevice};

/// Buffer size for packets
const BUFFER_SIZE: usize = 65535;

/// WireGuard server
pub struct WireGuardServer {
    /// Configuration
    config: WireGuardConfig,
    /// Our static private key
    static_private: [u8; 32],
    /// Our static public key
    static_public: [u8; 32],
    /// UDP socket bound to ListenPort
    socket: UdpSocket,
    /// TUN device for IP traffic
    tun: TunDevice,
    /// Route manager
    routes: RouteManager,
    /// Peer manager (tracks all configured peers)
    peers: PeerManager,
}

impl WireGuardServer {
    /// Create a new WireGuard server
    pub async fn new(config: WireGuardConfig) -> Result<Self, SecureGuardError> {
        // Get ListenPort (required for server mode)
        let listen_port = config.interface.listen_port.ok_or_else(|| {
            SecureGuardError::Config(ConfigError::MissingField {
                field: "ListenPort".to_string(),
            })
        })?;

        // Parse our interface address
        let our_address = config.interface.address.first().ok_or_else(|| {
            SecureGuardError::Config(ConfigError::MissingField {
                field: "Address".to_string(),
            })
        })?;

        // Create TUN device
        let tun = TunDevice::create(
            our_address.addr(),
            our_address.prefix_len(),
            config.interface.mtu.unwrap_or(1420),
        )
        .await?;

        // Create route manager
        let routes = RouteManager::new(tun.name().to_string());

        // Bind UDP socket to ListenPort
        let bind_addr = format!("0.0.0.0:{}", listen_port);
        let socket = UdpSocket::bind(&bind_addr).await.map_err(|e| {
            NetworkError::BindFailed {
                addr: bind_addr.clone(),
                reason: e.to_string(),
            }
        })?;

        tracing::info!("Server listening on UDP port {}", listen_port);

        // Compute our public key from private key
        let static_private = config.interface.private_key;
        let static_public = x25519::public_key(&static_private);

        // Initialize peer manager from config
        let mut peers = PeerManager::new();
        for peer_config in &config.peers {
            peers.add_peer(
                peer_config.public_key,
                peer_config.preshared_key,
                peer_config.allowed_ips.clone(),
            );
            tracing::info!(
                "Added peer: {} with AllowedIPs: {:?}",
                BASE64.encode(&peer_config.public_key[..8]),
                peer_config.allowed_ips
            );
        }

        Ok(Self {
            config,
            static_private,
            static_public,
            socket,
            tun,
            routes,
            peers,
        })
    }

    /// Run the server (main event loop)
    pub async fn run(&mut self) -> Result<(), SecureGuardError> {
        // Set up routes for peers' allowed IPs
        self.setup_routes().await?;

        // Main event loop
        self.event_loop().await
    }

    /// Set up routes for all peers' allowed IPs
    async fn setup_routes(&mut self) -> Result<(), SecureGuardError> {
        for peer in &self.config.peers {
            for network in &peer.allowed_ips {
                if let ipnet::IpNet::V4(v4net) = network {
                    if let Err(e) = self.routes.add_route(*v4net).await {
                        tracing::warn!("Failed to add route for {}: {}", network, e);
                    }
                }
            }
        }
        Ok(())
    }

    /// Main event loop
    async fn event_loop(&mut self) -> Result<(), SecureGuardError> {
        let mut tun_buf = [0u8; BUFFER_SIZE];
        let mut udp_buf = [0u8; BUFFER_SIZE];

        // Rekey check interval (every 10 seconds)
        let mut rekey_check: Interval = interval(Duration::from_secs(10));

        tracing::info!("Server event loop started");

        loop {
            tokio::select! {
                // Read from TUN -> find peer -> encrypt -> send via UDP
                result = self.tun.read(&mut tun_buf) => {
                    match result {
                        Ok(len) => {
                            if let Err(e) = self.handle_tun_packet(&tun_buf[..len]).await {
                                tracing::trace!("Error handling TUN packet: {}", e);
                            }
                        }
                        Err(e) => {
                            tracing::error!("TUN read error: {}", e);
                        }
                    }
                }

                // Read from UDP -> dispatch by message type
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

                // Periodic rekey check for all peers
                _ = rekey_check.tick() => {
                    // Server doesn't initiate rekeys - it responds to client rekeys
                    // But we could clean up expired sessions here if needed
                }
            }
        }
    }

    /// Handle incoming UDP packet
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
            MessageType::HandshakeInitiation => {
                self.handle_handshake_initiation(packet, from).await
            }
            MessageType::TransportData => self.handle_transport_packet(packet, from).await,
            // Server doesn't process HandshakeResponse or CookieReply
            // (those are for clients)
            _ => Ok(()),
        }
    }

    /// Process handshake initiation from a peer
    async fn handle_handshake_initiation(
        &mut self,
        packet: &[u8],
        from: SocketAddr,
    ) -> Result<(), SecureGuardError> {
        // 1. Parse initiation
        let initiation = HandshakeInitiation::from_bytes(packet)?;

        // 2. Verify MAC1 using our public key
        verify_initiation_mac1(packet, &self.static_public)?;

        // 3. Create responder handshake and process initiation
        let sender_index = generate_sender_index();
        let mut responder = ResponderHandshake::new(self.static_private, sender_index);

        // 4. Process initiation to get peer's public key
        let peer_public = responder.process_initiation(&initiation)?;

        // 5. Look up peer by public key
        let peer = self.peers.get_peer_mut(&peer_public).ok_or_else(|| {
            tracing::warn!("Unknown peer: {}", BASE64.encode(&peer_public[..8]));
            ProtocolError::InvalidSenderIndex {
                index: initiation.sender_index,
            }
        })?;

        // 6. Get PSK for this peer (if any)
        let psk = peer.psk;

        // 7. Create response
        let (response, result) = responder.create_response(psk, None)?;

        // 8. Send response
        self.socket.send_to(&response.to_bytes(), from).await.map_err(|e| {
            NetworkError::SendFailed {
                reason: e.to_string(),
            }
        })?;

        tracing::info!(
            "Handshake response sent to {} (peer: {})",
            from,
            BASE64.encode(&peer_public[..8])
        );

        // 9. Establish session
        let session = Session::new(
            result.local_index,
            result.remote_index,
            result.sending_key,
            result.receiving_key,
            from,
        );

        // 10. Update peer state
        self.peers.establish_session(&peer_public, session);

        // 11. Update peer's endpoint
        if let Some(peer) = self.peers.get_peer_mut(&peer_public) {
            peer.endpoint = Some(from);
        }

        tracing::info!("Session established with peer {}", BASE64.encode(&peer_public[..8]));

        Ok(())
    }

    /// Handle transport data from a peer
    async fn handle_transport_packet(
        &mut self,
        packet: &[u8],
        from: SocketAddr,
    ) -> Result<(), SecureGuardError> {
        let header = TransportHeader::from_bytes(packet)?;

        // Find peer by session index
        let peer = self.peers.find_by_index(header.receiver_index).ok_or(
            ProtocolError::InvalidSenderIndex {
                index: header.receiver_index,
            },
        )?;

        // Get session and decrypt
        let session = peer
            .find_session_by_index(header.receiver_index)
            .ok_or(ProtocolError::NoSession)?;

        let plaintext = session.transport.decrypt(packet)?;
        session.mark_received();

        // Update endpoint if changed (roaming)
        if peer.endpoint != Some(from) {
            tracing::info!("Peer endpoint changed to {}", from);
            peer.endpoint = Some(from);
        }

        // Write decrypted IP packet to TUN
        if !plaintext.is_empty() {
            self.tun.write(&plaintext).await?;
        }

        Ok(())
    }

    /// Handle outgoing packet from TUN (needs routing to correct peer)
    async fn handle_tun_packet(&mut self, packet: &[u8]) -> Result<(), SecureGuardError> {
        // Parse destination IP from packet
        let dest_ip = parse_ipv4_dest(packet)?;

        // Find peer whose AllowedIPs matches destination
        let peer = self.peers.find_by_allowed_ip_mut(dest_ip).ok_or_else(|| {
            tracing::trace!("No route to {}", dest_ip);
            NetworkError::NoEndpoint
        })?;

        // Get endpoint first (before borrowing session)
        let endpoint = peer.endpoint.ok_or(NetworkError::NoEndpoint)?;

        // Get session
        let session = peer.current_session_mut().ok_or(ProtocolError::NoSession)?;

        // Encrypt and send
        let remote_index = session.remote_index;
        let encrypted = session.transport.encrypt(remote_index, packet)?;
        session.mark_sent();

        self.socket.send_to(&encrypted, endpoint).await.map_err(|e| {
            NetworkError::SendFailed {
                reason: e.to_string(),
            }
        })?;

        Ok(())
    }

    /// Clean up routes on shutdown
    pub async fn cleanup(&mut self) -> Result<(), SecureGuardError> {
        tracing::info!("Server cleaning up routes...");
        self.routes.cleanup().await?;
        tracing::info!("Server cleanup complete");
        Ok(())
    }
}

/// Parse destination IPv4 address from an IP packet
fn parse_ipv4_dest(packet: &[u8]) -> Result<Ipv4Addr, SecureGuardError> {
    if packet.len() < 20 {
        return Err(ProtocolError::InvalidMessageLength {
            expected: 20,
            got: packet.len(),
        }
        .into());
    }

    // Check IP version
    let version = packet[0] >> 4;
    if version != 4 {
        return Err(ProtocolError::InvalidMessageType { msg_type: version }.into());
    }

    // IPv4 destination is bytes 16-19
    Ok(Ipv4Addr::new(packet[16], packet[17], packet[18], packet[19]))
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_parse_ipv4_dest() {
        // Minimal valid IPv4 header with destination 192.168.1.100
        let mut packet = [0u8; 20];
        packet[0] = 0x45; // Version 4, IHL 5
        packet[16] = 192;
        packet[17] = 168;
        packet[18] = 1;
        packet[19] = 100;

        let dest = parse_ipv4_dest(&packet).unwrap();
        assert_eq!(dest, Ipv4Addr::new(192, 168, 1, 100));
    }

    #[test]
    fn test_parse_ipv4_dest_too_short() {
        let packet = [0u8; 10];
        assert!(parse_ipv4_dest(&packet).is_err());
    }
}
