//! Authentication module for REST API
//!
//! Handles token generation, storage, and validation for the daemon HTTP server.

use axum::{
    body::Body,
    extract::State,
    http::{Request, StatusCode},
    middleware::Next,
    response::Response,
};
use base64::{engine::general_purpose::STANDARD as BASE64, Engine};
use rand::RngCore;
use std::path::PathBuf;
use std::sync::Arc;

/// Default token file path for Unix systems
#[cfg(unix)]
pub const DEFAULT_TOKEN_PATH: &str = "/var/run/secureguard/auth-token";

/// Default token file path for Windows
#[cfg(windows)]
pub const DEFAULT_TOKEN_PATH: &str = r"C:\ProgramData\SecureGuard\auth-token";

/// Authentication state shared across handlers
#[derive(Clone)]
pub struct AuthState {
    /// The valid authentication token
    token: Arc<String>,
}

impl AuthState {
    pub fn new(token: String) -> Self {
        Self {
            token: Arc::new(token),
        }
    }

    pub fn token(&self) -> &str {
        &self.token
    }
}

/// Generate a cryptographically secure 32-byte token, base64-encoded
pub fn generate_token() -> String {
    let mut bytes = [0u8; 32];
    rand::thread_rng().fill_bytes(&mut bytes);
    BASE64.encode(bytes)
}

/// Write the token to the specified file with appropriate permissions
pub fn write_token_file(token: &str, path: Option<PathBuf>) -> Result<PathBuf, std::io::Error> {
    let token_path = path.unwrap_or_else(|| PathBuf::from(DEFAULT_TOKEN_PATH));

    // Create parent directory if it doesn't exist
    if let Some(parent) = token_path.parent() {
        std::fs::create_dir_all(parent)?;
    }

    // Write token to file
    std::fs::write(&token_path, token)?;

    // Set appropriate permissions
    #[cfg(unix)]
    set_unix_permissions(&token_path)?;

    #[cfg(windows)]
    set_windows_permissions(&token_path)?;

    tracing::info!("Auth token written to {:?}", token_path);
    Ok(token_path)
}

/// Set Unix file permissions (0o640 - owner rw, group r)
#[cfg(unix)]
fn set_unix_permissions(path: &PathBuf) -> Result<(), std::io::Error> {
    use std::os::unix::fs::PermissionsExt;

    // Set file permissions to 0o640 (owner read/write, group read)
    let permissions = std::fs::Permissions::from_mode(0o640);
    std::fs::set_permissions(path, permissions)?;

    // Try to set group to 'secureguard' if it exists
    // This is best-effort - if the group doesn't exist, we continue with default group
    #[cfg(target_os = "macos")]
    {
        // On macOS, use dscl to check for group - simplified approach
        // The installer should create the group
        tracing::debug!("Token file created with 0o640 permissions");
    }

    #[cfg(target_os = "linux")]
    {
        // On Linux, try to set group ownership via chgrp
        // The installer should create the 'secureguard' group
        tracing::debug!("Token file created with 0o640 permissions");
    }

    Ok(())
}

/// Set Windows file permissions (ACL-based)
#[cfg(windows)]
fn set_windows_permissions(path: &PathBuf) -> Result<(), std::io::Error> {
    // On Windows, the installer sets up the directory ACLs
    // Files inherit from parent directory
    tracing::debug!("Token file created at {:?}", path);
    Ok(())
}

/// Read token from file
pub fn read_token_file(path: Option<PathBuf>) -> Result<String, std::io::Error> {
    let token_path = path.unwrap_or_else(|| PathBuf::from(DEFAULT_TOKEN_PATH));
    let token = std::fs::read_to_string(&token_path)?;
    Ok(token.trim().to_string())
}

/// Axum middleware for Bearer token authentication
pub async fn auth_middleware(
    State(auth_state): State<AuthState>,
    request: Request<Body>,
    next: Next,
) -> Result<Response, StatusCode> {
    // Extract Authorization header
    let auth_header = request
        .headers()
        .get("Authorization")
        .and_then(|h| h.to_str().ok());

    match auth_header {
        Some(header) if header.starts_with("Bearer ") => {
            let token = &header[7..]; // Skip "Bearer "
            if token == auth_state.token() {
                Ok(next.run(request).await)
            } else {
                tracing::warn!("Invalid auth token provided");
                Err(StatusCode::UNAUTHORIZED)
            }
        }
        Some(_) => {
            tracing::warn!("Malformed Authorization header");
            Err(StatusCode::UNAUTHORIZED)
        }
        None => {
            tracing::warn!("Missing Authorization header");
            Err(StatusCode::UNAUTHORIZED)
        }
    }
}

/// Extract and validate token from request (for SSE which may use query param)
pub fn validate_token_from_query(query_token: Option<&str>, auth_state: &AuthState) -> bool {
    match query_token {
        Some(token) => token == auth_state.token(),
        None => false,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn test_generate_token() {
        let token1 = generate_token();
        let token2 = generate_token();

        // Tokens should be different
        assert_ne!(token1, token2);

        // Tokens should be base64-encoded 32 bytes (44 chars with padding)
        assert_eq!(token1.len(), 44);
        assert_eq!(token2.len(), 44);

        // Should be valid base64
        assert!(BASE64.decode(&token1).is_ok());
        assert!(BASE64.decode(&token2).is_ok());
    }

    #[test]
    fn test_auth_state() {
        let token = generate_token();
        let auth_state = AuthState::new(token.clone());
        assert_eq!(auth_state.token(), &token);
    }
}
