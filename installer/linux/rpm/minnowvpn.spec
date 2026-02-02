Name:           minnowvpn
Version:        %{VERSION}
Release:        1%{?dist}
Summary:        MinnowVPN Client

License:        Proprietary
URL:            https://minnowvpn.com
Source0:        minnowvpn-%{VERSION}.tar.gz

Requires:       gtk3
Requires:       libsecret

%description
WireGuard-compatible VPN client with a modern GUI.
Includes background daemon service and Flutter desktop client.

%prep
%setup -q -n minnowvpn-%{VERSION}

%install
rm -rf %{buildroot}

# Create directories
mkdir -p %{buildroot}/usr/local/bin
mkdir -p %{buildroot}/opt/minnowvpn
mkdir -p %{buildroot}/etc/systemd/system
mkdir -p %{buildroot}/usr/share/applications
mkdir -p %{buildroot}/usr/share/icons/hicolor/48x48/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/128x128/apps
mkdir -p %{buildroot}/usr/share/icons/hicolor/256x256/apps
mkdir -p %{buildroot}/var/lib/minnowvpn
mkdir -p %{buildroot}/var/run/minnowvpn
mkdir -p %{buildroot}/var/log/minnowvpn

# Install daemon binary
install -m 755 minnowvpn-service %{buildroot}/usr/local/bin/

# Install Flutter client
cp -r flutter-bundle/* %{buildroot}/opt/minnowvpn/
chmod 755 %{buildroot}/opt/minnowvpn/minnowvpn_client

# Create symlink
ln -sf /opt/minnowvpn/minnowvpn_client %{buildroot}/usr/local/bin/minnowvpn

# Install service file
install -m 644 minnowvpn.service %{buildroot}/etc/systemd/system/

# Install desktop file
install -m 644 minnowvpn.desktop %{buildroot}/usr/share/applications/

# Install icons (properly sized - guaranteed to exist by build-rpm.sh)
install -m 644 icons/minnowvpn-48.png %{buildroot}/usr/share/icons/hicolor/48x48/apps/minnowvpn.png
install -m 644 icons/minnowvpn-128.png %{buildroot}/usr/share/icons/hicolor/128x128/apps/minnowvpn.png
install -m 644 icons/minnowvpn-256.png %{buildroot}/usr/share/icons/hicolor/256x256/apps/minnowvpn.png

%pre
# Pre-installation: Stop existing service
if systemctl is-active --quiet minnowvpn 2>/dev/null; then
    systemctl stop minnowvpn || true
    sleep 2
fi

if systemctl is-enabled --quiet minnowvpn 2>/dev/null; then
    systemctl disable minnowvpn || true
fi

# Remove old auth token
rm -f /var/run/minnowvpn/auth-token

%post
# Post-installation: Set up group and start service

# Create group
if ! getent group minnowvpn > /dev/null 2>&1; then
    groupadd -f minnowvpn
fi

# Set directory permissions
chown root:minnowvpn /var/run/minnowvpn
chmod 750 /var/run/minnowvpn
chmod 700 /var/lib/minnowvpn
chown root:minnowvpn /var/log/minnowvpn
chmod 750 /var/log/minnowvpn

# Set capabilities
setcap cap_net_admin,cap_net_raw,cap_net_bind_service=eip /usr/local/bin/minnowvpn-service 2>/dev/null || true

# Enable and start service (if systemd is running)
if pidof systemd &>/dev/null; then
    systemctl daemon-reload
    systemctl enable minnowvpn
    systemctl start minnowvpn
fi

# Update desktop database
update-desktop-database /usr/share/applications 2>/dev/null || true
gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true

%preun
# Pre-uninstall: Stop service
if [ $1 -eq 0 ]; then
    # Complete removal (not upgrade)
    if systemctl is-active --quiet minnowvpn 2>/dev/null; then
        systemctl stop minnowvpn || true
    fi
    if systemctl is-enabled --quiet minnowvpn 2>/dev/null; then
        systemctl disable minnowvpn || true
    fi
fi

%postun
# Post-uninstall: Cleanup
if [ $1 -eq 0 ]; then
    # Complete removal (not upgrade)
    rm -rf /var/run/minnowvpn
    systemctl daemon-reload 2>/dev/null || true
    update-desktop-database /usr/share/applications 2>/dev/null || true
    gtk-update-icon-cache -f -t /usr/share/icons/hicolor 2>/dev/null || true
fi

%files
%attr(755, root, root) /usr/local/bin/minnowvpn-service
/usr/local/bin/minnowvpn
/opt/minnowvpn/
%config /etc/systemd/system/minnowvpn.service
/usr/share/applications/minnowvpn.desktop
/usr/share/icons/hicolor/48x48/apps/minnowvpn.png
/usr/share/icons/hicolor/128x128/apps/minnowvpn.png
/usr/share/icons/hicolor/256x256/apps/minnowvpn.png
%dir %attr(700, root, root) /var/lib/minnowvpn
%dir %attr(750, root, minnowvpn) /var/run/minnowvpn
%dir %attr(750, root, minnowvpn) /var/log/minnowvpn

%changelog
* %(date +"%a %b %d %Y") MinnowVPN Team <support@minnowvpn.com> - %{version}-1
- Initial package
