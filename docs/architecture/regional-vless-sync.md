# Regional VLESS sync

After an authenticated session is established, XConnect reads the canonical
regional node list from `GET /api/agent-server/v1/nodes`. The response is the
source of truth for currently open, healthy regions.

For each returned `vless://` URI the client generates an Xray configuration,
writes it using a stable node-ID-derived filename, and registers a separate
local node. A ten-minute refresh keeps the local list aligned with the server;
nodes no longer returned by the endpoint are removed when the refresh succeeds.

The same Flutter service is used by iOS, Android, macOS, Windows, and Linux.
There is no client-side version cursor, ACK endpoint, device fingerprint, or
encrypted sync envelope in this flow. Authentication is the existing session
token/cookie, and the server owns region availability and node metadata.

The control plane selects Shared + Free nodes for Free users, Shared + Plus
nodes for Plus users, and only the specified team's nodes for Team users.
Blocked accounts receive no managed connections. Pool names do not determine
entitlements; the app consumes the authenticated account-scoped response and
the exact node domain/URI rather than inferring a plan from a hostname.

Custom imports are independent user-owned connections for all account types.
They appear before managed nodes and remain usable during account-sync errors,
team expiry or sign-out. Synchronization never overwrites or prunes their
configuration files or replaces an active custom connection. Managed metadata
cannot be relabeled as a custom connection to escape owner/team checks.

Shared visibility requires an Accounts release that includes Shared pools in
the user node-discovery endpoint. A healthy Shared node shown in the platform
administrator inventory is insufficient if that user-scoped API excludes it.
