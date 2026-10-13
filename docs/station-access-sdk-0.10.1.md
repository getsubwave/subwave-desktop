# Station access on SDK 0.10.1

Station preferences use normalized base URLs. The settings map retains eight
recents plus the current station. Returning to a private station restores its
format and password, then validates that password through `/api/station-auth`.
Removing a recent deletes its saved preferences without interrupting its live
session. A reconnect lasting 15 seconds checks for password rotation, with at
least two minutes between checks. Only HTTP 401 proves that a password is stale.

## Password storage

The SDK exposes `credentialsGet` and `credentialsSet`. Its macOS host uses
Keychain, and its Windows host uses Credential Manager. Those platforms store
one app-scoped vault record under `station-passwords-v1`. The record holds at
most nine SHA-256 station keys and base64 passwords. Base64 limits the record
to the SDK's 2560-byte secret bound. Encryption belongs to the OS credential
manager.

Migration reads the vault first, gives existing vault entries precedence over
legacy passwords, writes the merged record, and only then removes plaintext
passwords from settings. A failed vault read or write preserves the original
settings file. Newly entered passwords remain usable for the current session.

Linux uses plaintext passwords in the per-station settings map. The stock
SDK's `src/platform/linux/gtk_host.c` declares `native_sdk_secret_schema_t`
without libsecret's reserved ABI fields. An isolated Linux launch on Debian 13
crashed in `secret_schema_ref`, called through `secret_password_lookup_sync`
by the first `credentialsGet`. This happens even with an unavailable D-Bus
session. No SDK patch or replacement keychain FFI is included here. Re-enable
the Linux credential effect only after an SDK upgrade fixes that ABI and a
real isolated-keyring test passes.

The file read and write buffers allow 32 KB, including worst-case JSON escaping
for all retained station passwords and names. File effects have an explicit
filesystem permission because the existing `subwave-player` settings and
cache directories sit outside the runner's bundle-id directories.

## HTTP Basic station login

HTTP Basic station login is unsupported. `FetchOptions.headers` can authenticate
API requests, but `LoadImageOptions` and `PlayAudioOptions` have no header field.
The Linux host gives the URL to GStreamer playbin without setting authentication
properties. macOS creates an `AVURLAsset` with `options:nil`. Windows passes the
URL to `BeginCreateObjectFromURL` with no authentication property store or
credential callback. URL userinfo does not establish a supported authentication
contract across those hosts. Station addresses containing userinfo are rejected.

The reference branch's `docs/sdk-player-transport.md` and
`docs/webview-station-foundation.md` describe authenticated streaming through a
loopback relay and private SDK patches. That experiment is not used by this
player.

## Health checks

Both station-entry fields probe `/api/health`, require its controller JSON
response, and obtain the display name from `/api/dj` as a best-effort step.
Bare hosts try HTTPS before HTTP. Explicit schemes and HTTP 401 or 407 never
downgrade. A public HTTP station needs an explicit **Continue over insecure
HTTP** action. Localhost, LAN names, private IPv4, link-local addresses, and
local IPv6 addresses skip that warning.

Diagnostics explain timeout, station login, proxy login, controller routing,
TLS, and connection failures. TLS guidance follows the desktop OS. SDK 0.10.1
returns only an outcome enum and HTTP status, so the player shows those details
instead of an underlying network or certificate error that the SDK does not
expose.
