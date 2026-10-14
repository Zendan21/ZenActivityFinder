# ZenActivityFinder

A World of Warcraft 3.3.5 activity finder for creating, discovering and joining player-made activities.

ZenActivityFinder is being developed as part of the wider Zen addon suite and uses the same general design direction as the other Zen addons.

## Current direction

The next communication-layer milestone is **ZenConnect**: an embedded shared library that will let Zen addons communicate without requiring a separate third-party communication addon.

The design is intentionally similar to the way ZenStyling is embedded inside each addon:

- each Zen addon can ship ZenConnect
- only one shared ZenConnect instance runs on the client
- the newest compatible embedded copy wins
- Zen addons communicate through namespaces
- one shared transport is used instead of one channel per addon
- local addon-to-addon messaging and cross-player messaging use the same communication layer

See [docs/ZenConnect.md](docs/ZenConnect.md) for the architecture and migration plan.

## Planned ZenConnect migration

ZenActivityFinder will eventually move its communication responsibilities onto ZenConnect, including:

- presence
- listing create/update/remove
- listing refresh
- invite requests and responses
- interest updates
- applicant metadata
- Orb Farm activity metadata

Low-level communication concerns such as channel management, chunking, throttling, reconnect handling and message routing should live in ZenConnect rather than in the Activity Finder itself.

## Goal

Keep ZenActivityFinder independently installable while allowing it to become part of a consistent Zen ecosystem when other Zen addons are installed.
