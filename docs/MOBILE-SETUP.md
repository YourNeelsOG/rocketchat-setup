# Connecting clients

## Before handing this to users

Check three things yourself first. Each has caused more support requests than
anything else in the client setup.

1. `RC_ROOT_URL` matches exactly what users will type, including the scheme and
   any non-standard port. A mismatch produces a client that loads and then
   silently fails to receive messages.
2. The WebSocket upgrade works. Realtime messaging depends on it; without it
   the interface appears and nothing ever arrives.
3. In `local-tls` mode, the CA is installed on the device. The mobile apps do
   not offer a "proceed anyway" option the way browsers do.

## Android

1. Install **Rocket.Chat** from Google Play.
2. Open it, choose **Join a workspace** or **Connect to a server**.
3. Enter the full URL, including the scheme: `https://chat.example.com`
4. Sign in.

For `local-tls`, install the CA first:

1. Transfer `certs/ca.crt` to the device.
2. **Settings → Security → Encryption & credentials → Install a certificate →
   CA certificate**, then select the file.
3. Android warns that a third party may monitor traffic. That warning is
   accurate and is what installing a CA means; accept it only for a CA you
   generated yourself.

Android 11 and later restrict user-installed CAs for some applications. If the
app still refuses after installing the CA, `behind-proxy` mode with a publicly
trusted certificate is the reliable path.

## iOS and iPadOS

1. Install **Rocket.Chat** from the App Store.
2. **Connect to a server**, enter `https://chat.example.com`, sign in.

For `local-tls`, iOS needs two separate steps and the second is easy to miss:

1. Email or AirDrop `certs/ca.crt` to the device and open it.
2. **Settings → General → VPN & Device Management** → install the profile.
3. **Settings → General → About → Certificate Trust Settings** → enable full
   trust for the certificate.

Step 3 is mandatory. Installing the profile alone does not make iOS trust it,
and the failure looks identical to the certificate not being installed.

## Desktop application

1. Download from <https://www.rocket.chat/download-legacy>
2. **Add new server**, enter the URL, sign in.

For `local-tls` the desktop app uses the operating system trust store, so
installing the CA at the OS level covers it:

```bash
# Linux (Debian/Ubuntu)
sudo cp certs/ca.crt /usr/local/share/ca-certificates/rocketchat-local.crt
sudo update-ca-certificates

# Linux (Arch)
sudo cp certs/ca.crt /etc/ca-certificates/trust-source/anchors/
sudo trust extract-compat

# macOS
sudo security add-trusted-cert -d -r trustRoot \
  -k /Library/Keychains/System.keychain certs/ca.crt
```

Windows: double-click `ca.crt`, **Install Certificate → Local Machine →
Trusted Root Certification Authorities**.

## Browser

Navigate to the URL. Nothing else is required in `public-tls` mode.

In `local-tls` mode without the CA installed, browsers show a warning that can
be clicked through. It will reappear, and users will learn to dismiss
certificate warnings, which is a habit worth not teaching. Install the CA.

## Troubleshooting

**"Cannot connect to server" / the URL is rejected**

Confirm the server answers at all:

```bash
curl -I https://chat.example.com          # expect 200
curl -sk https://chat.example.com/api/info   # expect a JSON version
```

Then confirm `RC_ROOT_URL` in `.env` matches what you typed, character for
character. A trailing slash, a missing port, or `http` where the client used
`https` are all enough.

**Connects, but messages never arrive**

The WebSocket upgrade is not getting through. In `behind-proxy` mode this is
almost always the cause, and almost always missing headers on your proxy:

```nginx
proxy_http_version 1.1;
proxy_set_header Upgrade $http_upgrade;
proxy_set_header Connection "upgrade";
```

Check for rejected upgrades:

```bash
docker compose logs --tail 100 rocketchat | grep -i websocket
```

**Certificate rejected on mobile (local-tls)**

The CA is not installed, or on iOS step 3 was skipped. Verify the certificate
covers the name being used:

```bash
openssl x509 -in certs/server.crt -noout -text | grep -A1 'Subject Alternative Name'
```

A name not listed there will be rejected regardless of CA trust. Modern clients
ignore the CommonName field entirely and look only at the SAN list.

**Files upload but will not open**

`FileUpload_S3_Proxy_Uploads` is false. It should be true in this stack; see
[ARCHITECTURE.md](ARCHITECTURE.md). Check:

```bash
docker compose exec rocketchat env | grep Proxy_Uploads
```

**Push notifications do not arrive**

Self-hosted Rocket.Chat routes push through Rocket.Chat's gateway, which
requires registering the workspace (Admin → Subscription). Without it, the apps
receive messages only while open. This is an upstream product decision, not
something this deployment configures.

## For your users

Something like this is usually enough:

> **Chat server:** `https://chat.example.com`
>
> 1. Install "Rocket.Chat" from the App Store or Google Play
> 2. Choose "Connect to a server" and enter the address above
> 3. Sign in with the account you were sent
>
> Works in a browser at the same address, and there is a desktop app at
> rocket.chat/download-legacy.

In `local-tls` mode, add the CA file and its install steps to that message, and
say plainly that the app will not connect until it is done.
