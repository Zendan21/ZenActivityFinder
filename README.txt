ZENACTIVITYFINDER 2.1.1
======================

ZenActivityFinder is the renamed and rebuilt Activity Finder addon for the Project Ebonhold 3.3.5 client.

REQUIREMENTS
------------
- EbonAPI 2.1.2 or newer is required and must be enabled.
- ZenStylingPack 1.1.0 is embedded directly inside this addon; no separate styling addon is required.

INSTALL
-------
1. Install/enable EbonAPI.
2. Copy the ZenActivityFinder folder into Interface\AddOns.
3. Remove or disable the old RavioliFamilyActivityFinder addon to avoid running two finders at once.
4. Restart WoW or /reload.
5. Open with /zaf or /zenactivity. /ravfinder remains as a legacy shortcut.

WHAT CHANGED IN 2.1.1
---------------------
- Added a native Orb Farms category for 5-player orb-farming groups.
- Added a + Orb Farm quick-create button with Trial of the Champion / RDF event detection.
- Orb listings automatically advertise the role currently needed: Tank, Healer, Tank/Healer, any role, or all roles.
- Orb listings carry their farm mode, event boss, and role need over EbonAPI. Older ZenActivityFinder 2.0 clients safely ignore the extra fields.
- Request Invite is disabled when your class cannot fill the role currently requested by an Orb Farm.
- Orb applicant rows show the applicant class role icons.
- Added /zaf orb and /zaf orbhost.
- Orb Farms are implemented entirely inside ZenActivityFinder. There is no OrbQueue dependency, bridge, shared channel, or external integration.

WHAT CHANGED IN 2.0.0
---------------------
- Renamed from Ravioli Family Activity Finder to ZenActivityFinder.
- Communication has been moved to EbonAPI's managed shared channel.
- The addon no longer joins, filters, or transmits protocol traffic through its own RavioliFinder chat channel.
- EbonAPI now handles channel discovery, message framing/chunking, sender delivery, throttling, and reconnection.
- Activity listings, removals, invite requests/responses, presence, interest, and refresh messages are all sent through EbonAPI.
- ZenStylingPack 1.1.0 is embedded and used for panels, buttons, text, inputs, hover states, accents, fonts, opacity, and scale.
- Added an Appearance button in Settings and /zaf appearance.
- Styling can be local to ZenActivityFinder or shared globally with other ZenStylingPack addons through EbonAPI.
- Existing activity notifications, toasts, Interested, Share, applicants, game-mode checks, and listing expiry remain available.

COMMANDS
--------
/zaf                 Toggle ZenActivityFinder
/zaf settings        Open activity settings
/zaf orb             Open the Orb Farms category
/zaf orbhost         Create/refresh your Orb Farm listing
/zaf appearance      Open Zen styling controls
/zaf notifications   Toggle activity notifications
/zaf network         Show EbonAPI/network diagnostics
/zaf reset           Reset window/launcher positions
/zaf clear           Clear your local listings
/zaf lock            Lock/unlock the floating launcher

NETWORKING
----------
ZenActivityFinder uses EbonAPI 2.1.x as its only addon-protocol transport. Normal player-initiated chat actions such as Share to Guild/Party/Raid and invite-failure whispers still use Blizzard chat APIs because those are visible player messages, not addon synchronization traffic.

APPEARANCE
----------
The embedded ZenStylingPack provides:
- Zen Classic
- Zen Obsidian
- Zen Glass
- Zen Flat
- Zen Brutal
- Zen Neon

It also supports accent colour, panel opacity, window scale, and font selection. When Global (EbonAPI) is selected, compatible Zen addons can share the same appearance preferences.

NOTIFICATIONS
-------------
Activity notifications remain optional. Turning off Enable activity notifications suppresses pop-up toasts, unread attention, launcher glow, sounds, and notification chat messages while listings continue to synchronize quietly through EbonAPI.

UPGRADING FROM RAVIOLI FAMILY ACTIVITY FINDER
----------------------------------------------
Because the addon folder and SavedVariables name changed, ZenActivityFinder starts with its own settings database. The old addon should be disabled/removed after installing this build. Your old SavedVariables file is not deleted by this addon.
