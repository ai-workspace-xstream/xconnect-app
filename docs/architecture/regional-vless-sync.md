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
