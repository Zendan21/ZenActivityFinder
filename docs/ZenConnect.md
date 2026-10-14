# ZenConnect Architecture

ZenConnect is the planned embedded communication layer for the Zen addon suite.

The goal is to remove the requirement for Zen addons to depend on an external communication addon while still allowing independently installed Zen addons to communicate locally and between players.

## Design goals

- Embedded in every Zen addon, similar to ZenStyling.
- No separate ZenConnect addon required.
- One active shared ZenConnect instance per WoW client.
- Version arbitration so the newest embedded copy wins.
- One shared transport for all Zen addons.
- Namespaced messages so addons do not need separate communication channels.
- Local addon-to-addon event bus.
- Cross-player message routing.
- Chunking and reassembly for larger payloads.
- Outgoing queue and throttling.
- Sender identification and duplicate suppression.
- Presence / heartbeat support.
- Protocol and capability versioning.
- Reconnect handling.
- Optional debug logging.
- Backwards-compatible protocol evolution where practical.

## Embedded layout

Each addon can ship the library:

```text
ZenActivityFinder/
├── ZenActivityFinder.lua
├── Libs/
│   ├── ZenStyling/
│   └── ZenConnect/
└── ZenActivityFinder.toc

ZenProfessions/
├── ZenProfessions.lua
├── Libs/
│   ├── ZenStyling/
│   └── ZenConnect/
└── ZenProfessions.toc
```

All embedded copies resolve to one shared global instance:

```lua
_G.ZenConnect
```

A newer embedded copy may upgrade the shared instance during addon loading.

## Local addon communication

Zen addons should be able to publish and subscribe to local events without knowing about each other directly.

```lua
ZenConnect:Publish("STYLE_CHANGED", settings)

ZenConnect:Subscribe("STYLE_CHANGED", function(settings)
    -- respond to the change
end)
```

Potential local events include:

- style changes
- addon version announcements
- suite notifications
- settings changes
- unread badge changes
- addon availability / capability changes

## Cross-player communication

Addons register a namespace with ZenConnect:

```lua
ZenConnect:Register("ZenActivityFinder", {
    namespace = "ZAF",
    version = "2.2.0",
    protocol = 1,
})
```

They can then send logical messages:

```lua
ZenConnect:Send("ZAF", "LISTING_CREATE", payload)
```

ZenConnect owns:

1. serialization
2. message IDs
3. chunking
4. throttling
5. transport
6. reassembly
7. duplicate rejection
8. routing back to the correct addon

The addon owns only its own payload and behaviour.

## Shared transport

Zen addons should not create independent communication channels.

Avoid:

```text
ZenActivityFinder channel
ZenCommunityChallenges channel
ZenOrbFarm channel
ZenWhatever channel
```

Prefer one ZenConnect transport:

```text
ZenConnect
├── ZAF  ZenActivityFinder
├── ZCC  ZenCommunityChallenges
├── ZST  ZenStyling
└── future Zen addons
```

For WoW 3.3.5 clients, ZenConnect may still need one underlying shared channel for users who are not already connected through party, raid or guild channels. That transport should be owned entirely by ZenConnect and hidden from addon feature code.

## Message envelope

A compact v1 message envelope could follow this shape:

```text
ZC1|ZAF|LISTING_CREATE|message-id|chunk-info|payload
```

Where:

- `ZC1` = ZenConnect protocol version 1
- `ZAF` = addon namespace
- `LISTING_CREATE` = logical event
- `message-id` = unique message identifier
- `chunk-info` = chunk sequence metadata when required
- `payload` = serialized addon data

The exact wire format should be finalized during implementation and kept internal to ZenConnect.

## Presence and capabilities

ZenConnect should track compatible peers and the capabilities they advertise.

Example conceptual API:

```lua
ZenConnect:GetPeers("ZAF")
```

Possible result:

```text
PlayerA   ZenActivityFinder 2.2.0   protocol 1
PlayerB   ZenActivityFinder 2.1.1   protocol 1
```

This can be used for compatibility checks and feature negotiation.

## Version arbitration

Every embedded copy exposes a library and protocol version.

Example:

```lua
ZenConnect.VERSION = "1.0.0"
ZenConnect.PROTOCOL = 1
```

If multiple Zen addons embed ZenConnect, the newest compatible copy should initialize or upgrade the shared global instance. Loading several Zen addons must not create several simultaneous transports.

## ZenActivityFinder migration

ZenActivityFinder should eventually depend on ZenConnect rather than EbonAPI.

The Activity Finder should send logical events such as:

- presence
- listing create/update/remove
- listing refresh
- invite request / response
- interest changes
- applicant metadata
- Orb Farm metadata
- notification-related shared state where required

ZenActivityFinder should not contain channel management, reconnect logic, message chunking, throttling, or low-level peer routing once the migration is complete.

## ZenStyling migration

ZenStyling can also use ZenConnect for local/global Zen suite synchronization.

That would make the suite architecture:

```text
Zen addons
├── ZenActivityFinder
├── ZenProfessions
├── ZenCommunityChallenges
├── ZenUI
└── future addons
        │
        ├── ZenStyling
        │      └── visuals/settings
        │
        └── ZenConnect
               └── communication
```

## Initial implementation roadmap

1. Build ZenConnect 1.0.0 as an embedded library.
2. Implement version arbitration and one-instance initialization.
3. Add the local event bus.
4. Add namespaced message routing.
5. Add one shared WoW 3.3.5 transport.
6. Add queueing, throttling, chunking and reassembly.
7. Add presence and capability discovery.
8. Migrate ZenActivityFinder from EbonAPI to ZenConnect.
9. Migrate ZenStyling global synchronization.
10. Migrate other Zen addons as needed.
11. Remove direct EbonAPI dependencies after in-game compatibility testing.

## Non-goals for v1

ZenConnect should remain a focused communication library. It does not need to reproduce unrelated EbonAPI UI, localization, skinning or addon-specific features.

ZenStyling remains responsible for UI/appearance concerns.
