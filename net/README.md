# Minimal multiplayer (TCP/IP)

A deliberately small host/join layer. No Godot RPCs, no scene replication —
just length-prefixed JSON over `TCPServer` / `StreamPeerTCP`.

## Use

1. On one instance: **Multiplayer → Host** (default port `7777`), then pick a map.
2. On another instance: **Multiplayer → Join** with the host's IP and port.
   The client loads whatever map the host picked.
3. **Esc → Main Menu** closes the connection.

## What syncs

- Player position/rotation and camera pitch (30 Hz). Other players are shown
  as blue capsules labelled `P2`, `P3`, ...
- Held objects follow their owner, so pickup/drop is visible to everyone.
- `RigidBody3D` transforms (host-authoritative, 15 Hz). Clients freeze these
  bodies and follow snapshots; the host runs normal Jolt physics.
- Duplicate / delete / scale are detected by a 5 Hz scan of `RigidBody3D`
  nodes and sent as spawn / despawn / scale events. Newly created objects are
  renamed `N1`, `N2`, ... and moved under a `NetObjects` node so paths match
  on every peer.

## Wire format

`[4-byte big-endian length][UTF-8 JSON object]`

Message types: `hello`, `map`, `player`, `states`, `spawn`, `despawn`, `scale`,
`leave`, `bye`. See `net.gd` for payloads.

## Known limits (intentional for now)

- No authentication, no encryption, no latency compensation or interpolation.
- The host is authoritative for objects; clients do not simulate them freely.
- Map/static geometry must be the same on every peer (the host sends the path).
- A peer that loads a different map build can desync object keys.
