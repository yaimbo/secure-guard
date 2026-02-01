Name:           secureguard
Version:        %{VERSION}
Release:        1%{?dist}
Summary:        MinnowVPN Client

License:        Proprietary
URL:            https://minnowvpn.com
Source0:        secureguard-%{VERSION}.tar.gz

Requires:       gtk3
Requires:       libsecret

%description
WireGuard-compatible VPN client with a modern GUI.
Includes background daemon service and Flutter desktop client.

%prep
%setup -q -n secureguard-%{VERSION}

%install
rm -rf %{buildroot}

# Create directories
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/opt/secureguard
mkdir -p %{buildroot}/etc/systemd/system
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/48x48/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/128x128/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps
mkdir -p %{buildroot}/var/lib/secureguard
mkdir -p %{buildroot}/var/run/secureguard
mkdir -p %{buildroot}/var/log/secureguard

# Install daemon binary
install -m 755 secureguard-service %{buildroot}/usr/local/bin/

# Install Flutter client
cp -r flutter-bundle/* %{buildroot}/opt/secureguard/
chmod 755 %{buildroot}/opt/secureguard/secureguard_client

# Create symlink
ln -sf /opt/secureguard/secureguard_client %{buildroot}/usr/local/bin/secureguard

# Install service file
install -m 644 secureguard.service %{buildroot}/etc/systemd/system/

# Install desktop file
install -m 644 secureguard.desktop %{buildroot}/usr/share/applications/

# Install icons (properly sized - guaranteed to exist by build-rpm.sh)
install -m 644 icons/secureguard-48.png %{buildroot}/usr/share/icons/hicolor/48x48/apps/secureguard.png
install -m 644 icons/secureguard-128.png %{buildroot}/usr/share/icons/hicolor/128x128/apps/secureguard.png
install -m 644 icons/secureguard-256.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/secureguard.png

%pre
# Pre-installation: Stop existing service
if systemctl is-active --quiet secureguard 2>/dev/null; then
    systemctl stop secureguard || true
    sleep 2
fi

if systemctl is-enabled --quiet secureguard 2>/dev/null; then
    systemctl disable secureguard || true
fi

# Remove old auth token
rm -f /var/run/secureguard/auth-token

%post
# Post-installation: Set up group and start service

# Create group
if ! getent group secureguard > /dev/null 2>&1; then
    groupadd -f secureguard
fi

# Set directory permissions
chown root:secureguard /var/run/secureguard
chmod 750 /var/run/secureguard
chmod 700 /var/lib/secureguard
chown root:secureguard /var/log/secureguard
chmod 750 /var/log/secureguard

# Set capabilities
setcap cap_net_admin,cap_net_raw,cap_net_bind_service=eip /usr/local/bin/secureguard-service 2>/dev/null || true

# Enable and start service (if systemd is running)
if pidof systemd &>/dev/null; then
    systemctl daemon-reload
    systemctl enable secureguard
    systemctl start secureguard
fi

# Update desktop database
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true

%preun
# Pre-uninstall: Stop service
if [ $1 -eq 0 ]; then
    # Complete removal (not upgrade)
    if systemctl is-active --quiet secureguard 2>/dev/null; then
        systemctl stop secureguard || true
    fi
    if systemctl is-enabled --quiet secureguard 2>/dev/null; then
        systemctl disable secureguard || true
    fi
fi

%postun
# Post-uninstall: Cleanup
if [ $1 -eq 0 ]; then
    # Complete removal (not upgrade)
    rm -rf /var/run/secureguard
    systemctl daemon-reload 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi

%files
%attr(755, root, root) /usr/local/bin/secureguard-service
/usr/local/bin/secureguard
/opt/secureguard/
%config /etc/systemd/system/secureguard.service
/usr/share/applications/secureguard.desktop
/usr/share/icons/hicolor/48x48/apps/secureguard.png
/usr/share/icons/hicolor/128x128/apps/secureguard.png
/usr/share/icons/hicolor/256x256/apps/secureguard.png
%dir %attr(700, root, root) /var/lib/secureguard
%dir %attr(750, root, secureguard) /var/run/secureguard
%dir %attr(750, root, secureguard) /var/log/secureguard

%changelog
* %(date +"%a %b %d %Y") MinnowVPN Team <support@minnowvpn.com> - %{version}-1
- Initial package
