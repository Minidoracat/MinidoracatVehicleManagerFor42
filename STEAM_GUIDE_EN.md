<!-- 指南網址：https://steamcommunity.com/sharedfiles/filedetails/?id=3817840709 -->
<!-- Steam guide source (English): the full reference for this mod; the Workshop description only summarizes. Format and sync: pz-family-docs/release.md「完整說明：Steam 指南」 -->
<!-- 標題：📖 Vehicle Manager Mod Guide: Claims, Protection & Fleet -->
<!-- 摘要：Illustrated guide to the Minidoracat Vehicle Manager mod: claiming cars and what claims protect, damage guard, sharing, the fleet window, minimap tracking, paid slots, admin tools, and moving from Mysterious Vehicle Claim Key. -->
=== 🚀 Quick start
[b]繁體中文版：[/b][url=https://steamcommunity.com/sharedfiles/filedetails/?id=3817840665]車輛管理 MOD 完整說明[/url]

The mod on Steam Workshop:
https://steamcommunity.com/sharedfiles/filedetails/?id=3813972279

Vehicle Manager lets you claim a car to your account so other players can no longer drive it, siphon its fuel, strip its parts or tow it away. You can share it with friends or your faction and manage your cars from a fleet window and the minimap.
[olist]
[*] [b]Server setup[/b]: enable this mod and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url].
[list]
[*] To see your cars on the map: add [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap[/url]
[*] To let players buy claim slots: add [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125]Minidoracat Economy[/url]
[/list]
[*] [b]Claim[/b]: right-click next to a car, choose "Vehicle Manager → Claim vehicle", and confirm what the protection covers.
[*] [b]Manage[/b]: open the fleet window with the steering wheel icon in the family toolbar to view, rename or share your cars.
[/olist]
{{img:01-claim-menu-en.jpg}}
{{img:02-claim-confirm-en.jpg}}
=== 🧰 Claiming and protection
{{img:03-protected-en.jpg}}
[list]
[*] [b]Tied to your account[/b]: you keep your cars when your character dies.
[*] [b]How many[/b]: the server sets how many cars each player can claim.
[*] [b]Players without permission cannot[/b]:
[list]
[*] open or close doors, unlock, get in, start the engine
[*] add or siphon fuel, deflate tires
[*] install or remove parts, repair, smash windows, tow
[*] install/remove AutoDrive GPS and autopilot modules, or take the headphones out of the car radio
[/list]
[*] [b]When blocked[/b]: they see "This vehicle is claimed; you need the owner's share to use it" and the car stays as it was.
[*] [b]While another car tows it[/b]: if someone without tow permission gets in the driver's seat of the car towing yours, your car is unhitched and stays where it is, and you get a notice. The towing car isn't protected unless it's claimed too, so it can be driven away.
[*] [b]AutoDrive summon[/b]: calling the car over with AutoDrive needs the Drive permission for it; if the share is taken back mid-summon, the car stops.
[*] [b]Who owns it[/b]: right-click next to the car and open Vehicle Manager: the first line shows the owner's account name; for cars shared with you or with everyone, the next line lists what you can do.
[*] [b]Weapons aren't blocked[/b]: to keep a parked car safe from axes and guns, see "Damage guard".
[*] [b]No key needed[/b]: owners can unlock, open doors (without the alarm) and start the car without a physical key (servers can turn this off).
[/list]
[h3]Containers[/h3]
They follow permissions; without permission they don't show up in the inventory.
[table]
[tr][th]Container[/th][th]Permission needed[/th][/tr]
[tr][td]Trunk, truck bed, trailers, modded cargo boxes[/td][td]Trunk[/td][/tr]
[tr][td]Seats, glovebox[/td][td]Ride[/td][/tr]
[/table]
=== 🧰 Damage guard
Claiming stops other players from driving, opening or stripping your car; damage guard is what keeps a parked car safe from axes and guns.
[h3]When it works[/h3]
[list]
[*] [b]Active[/b]: while no owner or shared player is inside and the car isn't being towed or summoned by AutoDrive, weapons (melee or guns) can't damage a claimed car.
[*] [b]Paused[/b]: while someone is inside, the car is towed or AutoDrive is summoning it; it starts again when they get out or the summon ends.
[*] [b]While driving[/b]: crashes and zombies damage the car as usual, and that damage isn't repaired.
[/list]
[h3]Repairs[/h3]
[list]
[*] [b]How often[/b]: about every 10 seconds the server repairs damage, puts back broken windows and clears the broken glass.
[*] [b]Tampered durability[/b]: durability lowered directly by a cheating client or another mod is repaired at the next check too.
[*] [b]Not restored[/b]: fuel, battery charge and cargo; parts removed or windows smashed by the owner or someone with permission.
[/list]
[h3]Attacks and notices[/h3]
[list]
[*] [b]What an attacker sees[/b]: "This vehicle has damage guard; weapons cannot damage it"; on a car without damage guard, "This vehicle is claimed; its owner will be notified".
[*] [b]Owner notices[/b]: when someone hits your car with a weapon (melee or gunfire, anywhere on the car), you're told who, which car and whether damage guard stopped it.
[list]
[*] At most once a minute per attacker
[*] While you're offline it goes to the Notices tab of the fleet window
[*] Players you shared Salvage with don't count as attackers
[/list]
[*] [b]Which cars have it[/b]: in the fleet list, cars with damage guard show a shield and "Damage guard" on the right of their status line; vehicle details also show the damage guard status.
[/list]
[h3]Server modes[/h3]
Set by admins:
[table]
[tr][th]Mode[/th][th]Which cars have damage guard[/th][/tr]
[tr][td]All claimed vehicles (default)[/td][td]Every claimed car, for free[/td][/tr]
[tr][td]Off[/td][td]None[/td][/tr]
[tr][td]By guard slots[/td][td]Only some cars per player: 1 free guard slot by default, which admins can change for everyone or per player; with Economy on the server you can also buy or rent more, see "Paid slots (optional)"[/td][/tr]
[/table]
[h3]With guard slots[/h3]
[list]
[*] [b]Automatic[/b]: slots go to your earliest claimed cars, so changing the mode, claiming a new car or buying slots needs no setup.
[*] [b]Guard a different car[/b]: tick "Damage guard" in that car's details and the slot moves there.
[*] [b]Untick[/b]: gives the slot to the next car, and it won't come back on its own.
[*] [b]Fewer slots[/b]: cars you never ticked pause first (newest claim first), then the most recently ticked ones; you get a notice when cars pause.
[*] [b]Slots come back[/b]: those cars resume.
[/list]
=== 🧰 Sharing
{{img:06-public-share-en.jpg}}
[h3]Sharing with players or your faction[/h3]
[list]
[*] [b]Private by default[/b]: nothing is shared automatically.
[*] [b]Who[/b]: specific players or your faction, picking each permission.
[*] [b]Select all[/b]: the button above the switches turns them all on (including Salvage, Tow and Location) and then becomes "Select none".
[*] [b]Stop sharing[/b]: current shares are listed one per row, and one click stops each.
[*] [b]Owner only[/b]: rename, share, unclaim and transfer; these rights can't be shared.
[/list]
[h3]Share with everyone[/h3]
[list]
[*] Any player can use what you tick, limited to the permissions that can be public below.
[*] Other players see what everyone can do in the car's right-click menu.
[/list]
[table]
[tr][th]Permission[/th][th]Can be public[/th][/tr]
[tr][td]Ride, Drive, Trunk, Fuel, Repair[/td][td]Yes[/td][/tr]
[tr][td]Salvage, Tow, Location[/td][td]No, only for specific players or your faction[/td][/tr]
[/table]
{{img:07-shared-with-me-en.jpg}}
[h3]Faction renamed, disbanded or new leader[/h3]
[list]
[*] [b]Paused together[/b]: sharing with that faction pauses for all its cars at once and owners get a notice (kept in the Notices tab if they're offline).
[*] [b]What members see[/b]: which faction paused how many cars at the top of "Shared with me"; trying to use those cars tells them to ask the owner.
[*] [b]Restoring after a leader change[/b]: the owner finds the faction at the top of "My vehicles" in the fleet window, ticks the cars to restore (all ticked by default) and presses once; permissions stay the same.
[*] [b]After a rename or disband[/b]: share with the faction again.
[*] [b]Warning before handover[/b]: when a faction leader presses "Change Owner" in the vanilla faction window and the faction has cars shared with it, a warning first says how many cars will pause; the handover only happens after confirming.
[/list]
=== 🧰 Fleet window
{{img:04-fleet-window-en.jpg}}
[h3]Opening it[/h3]
[list]
[*] [b]Steering wheel icon[/b]: in the family toolbar; press "." to expand the toolbar when it's collapsed.
[*] [b]Hide the icon[/b]: untick "Show Vehicle Fleet button" under Options → MODS → Vehicle Manager and press Apply; then open the fleet from the right-click menu next to a car: "Vehicle Manager → Open fleet".
[*] [b]Admin override on[/b]: the icon always shows.
[/list]
[h3]Viewing and managing[/h3]
[list]
[*] [b]See[/b]: your cars, cars shared with you and where they were last seen.
[*] [b]Copy coordinates[/b]: click the coordinates in vehicle details to copy them and paste them to others.
[*] [b]Actions[/b]: rename, share, transfer or unclaim.
[*] [b]Choose guarded cars[/b]: when the server uses guard slots, choose which cars have damage guard in their details (see "Damage guard").
[/list]
[h3]Notices tab[/h3]
[list]
[*] [b]What it records[/b]:
[list]
[*] who hit which of your cars and whether damage guard stopped it
[*] who got in the car towing yours, which unhitched your car
[*] repairs done by damage guard
[*] cars that lost damage guard because your guard slots went down
[*] rented slots locking, unlocking or unclaiming cars
[/list]
[*] [b]Recorded while offline[/b]: when you log in with new notices you get a message, the steering wheel icon shows the unread count and the tab shows it as "Notices (count)". Opening the tab marks them read.
[*] [b]Grouped[/b]: repeated attacks on the same car by the same player within 10 minutes become one entry with a count.
[*] [b]Kept[/b]: 30 days, up to 50, on the server; only you can see yours.
[/list]
[h3]Lost cars and the keep date[/h3]
[list]
[*] [b]Unclaim lost vehicle[/b]: for a car that was destroyed, disappeared or can't be found when you can't get to it.
[list]
[*] It's unclaimed after a waiting period (24 hours by default) and frees your slot; the car stays claimed meanwhile.
[*] If the server sees it in that time, this is cancelled.
[*] Admins aren't notified.
[/list]
[*] [b]Kept until[/b]: if the owner doesn't log in for the number of days the server sets (30 by default), their cars are unclaimed automatically.
[list]
[*] Vehicle details show the date, which moves forward every time you play.
[*] Time the server is down doesn't count.
[/list]
[/list]
=== 🧰 Minimap tracking (optional)
{{img:05-map-marker-en.jpg}}
[list]
[*] [b]Needs[/b]: Minidoracat MiniMap installed.
[*] [b]Who sees them[/b]: your cars, and shared cars you have Location for, show on the minimap and world map. Nobody else can see them.
[*] [b]Custom markers[/b]: each car can have its own map icon, color and size; these settings are stored only on your computer.
[/list]
[h3]Map Display Settings[/h3]
In MiniMap's Map Display Settings (the minimap's gear), the Vehicle Manager category has a "Claimed vehicles" layer:
[list]
[*] [b]Markers[/b]: turn them on or off separately for the minimap and the world map, and set their overall size.
[*] [b]Names[/b]: choose "Show car names on the minimap" and "Show car names on the world map" separately; if names clutter the minimap, turn them off there to keep only the icons.
[*] [b]Live preview[/b]: shows the result right away.
[*] [b]Open fleet window[/b]: the button in the same category opens the fleet window.
[*] [b]Carried over[/b]: if you had turned off minimap car names before, that choice carries over.
[*] [b]Older MiniMap[/b]: the category only has "Show car names on the minimap"; untick it to keep only the icons on the minimap, and the world map still shows names.
[/list]
=== 🧰 Paid slots (optional)
{{img:08-claim-slots-en.jpg}}
[list]
[*] [b]Needs[/b]: a dedicated multiplayer server that also runs [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125]Minidoracat Economy[/url].
[*] [b]What's sold[/b]: the server owner can sell extra claim slots and damage guard slots for in-game money, to buy outright or to rent; nothing is sold by default.
[*] [b]Where[/b]: press "Claim slots" in the fleet window; guard slots are under "Guard slots" in a car's details.
[*] [b]Buy[/b]: several slots at once.
[*] [b]Rent[/b]: each rental is separate, with its own slot count and end date, and is renewed or set to auto-renew on its own.
[*] [b]Before you pay[/b]: you see the quantity, price, your balance before and after, and how many cars you can claim (or guard) afterwards; the slots work the moment you pay.
[*] [b]Price changes[/b]: if the rent, currency or period changes, auto-renew pauses until you accept the new terms.
[/list]
[h3]Expiry and refunds[/h3]
[list]
[*] [b]When a rented claim slot ends[/b]:
[list]
[*] A grace period starts (set by the server owner), and slots in grace can't be used for new claims.
[*] Cars over your limit are locked, newest first: neither you nor shared players can use them, and renewing or unclaiming other cars unlocks them right away.
[*] If you're still over the limit when the grace period ends, the locked cars are unclaimed.
[*] You get a notice at every step (also kept in the Notices tab), and the fleet window shows when the grace period ends.
[/list]
[*] [b]When a rented guard slot ends[/b]: cars over your guard slots only lose damage guard; they stay yours.
[*] [b]Refunds[/b]: only lower how many new cars you can claim; cars you already claimed stay claimed.
[/list]
[h3]Server owner settings[/h3]
[list]
[*] [b]Two ways[/b]: edit the settings files on the server, or admins open "Paid claim slot settings" or "Paid guard slot settings" from the Admin tab or the slots window.
[*] [b]What you can change[/b]: prices, currencies, limits, periods and grace hours.
[*] [b]Logged[/b]: each change needs a reason and is logged.
[/list]
=== ⚙️ Admin tools
{{img:09-admin-en.jpg}}
[h3]Admin tab[/h3]
[list]
[*] [b]Player list[/b]: players with their claimed count and limit; click a player to expand their cars.
[*] [b]Per player[/b]: adjust their basic slots, or unclaim a problem vehicle as admin.
[*] [b]Player details[/b]: when they were last online.
[*] [b]Teleport to vehicle[/b]: in vehicle details, goes to where the car was last seen.
[/list]
[h3]Server settings[/h3]
Edited right in the Admin tab; these are the same settings as the sandbox options:
[list]
[*] Default slots for all players
[*] Auto-unclaim days (0 = never)
[*] Damage guard mode: Off / All claimed vehicles / By guard slots
[*] Guard slots per player; with guard slots you can also set them for one player
[/list]
[h3]Override: use any vehicle[/h3]
[list]
[*] [b]Default[/b]: admins are blocked like any other player.
[*] [b]Turn it on[/b]: "Override: use any vehicle" in the Admin tab lets you use someone else's car.
[*] [b]Logged[/b]: every use is logged.
[*] [b]Red frame[/b]: the steering wheel icon in the family toolbar gets a red frame while it's on.
[*] [b]Turns off automatically[/b]: when you log in again or the server restarts.
[/list]
[h3]Identity check (SteamID)[/h3]
[list]
[*] [b]Run it once after installing[/b]: on a Steam server, press "Import accounts from the whitelist" under "Identity check (SteamID)" in the Admin tab soon after installing this mod, to bind existing accounts to the Steam account they log in with. Until then, accounts that aren't bound yet are matched by name only; players who register later are bound automatically when they create a character, so you don't need to press it again.
[/list]
[h3]Split-screen and AllowCoop[/h3]
[list]
[*] [b]Impersonation risk[/b]: in vanilla, split-screen players type their own name and the server doesn't verify it, while vanilla safehouses and factions trust names, so other players can be impersonated.
[*] [b]Recommendation[/b]: if your server doesn't need split-screen, set AllowCoop to false in the server settings (this mod already gives split-screen players no vehicle access).
[/list]
=== ⚙️ Moving from Mysterious Vehicle Claim Key
For admins:
[olist]
[*] [b]Back up[/b]: make a full backup of the save (including the world save folder).
[*] [b]Add this mod[/b]: add it to the server (MVCK can stay for now) and start the server.
[*] [b]Import[/b]: press "Import all claims from MVCK" in the Admin tab of the fleet window.
[list]
[*] Loaded vehicles move over at once, the rest the next time they load
[*] Vehicles still on a trailer move over when unloaded
[*] The window shows how many were imported, bound now and still waiting
[/list]
[*] [b]Press it again anytime[/b]: it only picks up claims made in MVCK since, without duplicates, and never deletes MVCK data.
[*] [b]Remove MVCK[/b]: once you're happy, remove it from the server yourself. While both mods run, both protections apply, and vehicles claimed in MVCK can't be claimed with this mod; the import moves them to their owners.
[/olist]
[h3]How permissions move over[/h3]
MVCK public permissions become "Share with everyone":
[table]
[tr][th]MVCK allows everyone to[/th][th]Vehicle Manager permission[/th][/tr]
[tr][td]Ride[/td][td]Ride[/td][/tr]
[tr][td]Drive[/td][td]Drive[/td][/tr]
[tr][td]Open the trunk[/td][td]Trunk[/td][/tr]
[tr][td]Siphon fuel[/td][td]Fuel[/td][/tr]
[tr][td]Inflate tires[/td][td]Repair[/td][/tr]
[/table]
[list]
[*] [b]Not imported[/b]: other public permissions (taking parts, deflating, smashing windows and so on) and per-player permissions, so owners need to share again.
[*] [b]Imports that never load[/b]: cleared after the number of days set in sandbox options (30 by default); owners can also press "Unclaim vehicle" on such a row to free the slot right away.
[/list]
=== ⚠️ What is protected
[list]
[*] [b]Claims cover normal player actions[/b]: weapon damage depends on "Damage guard".
[*] [b]Empty parked cars[/b]: zombies don't attack them, and other players driving into one don't damage it; while someone is inside, zombies and crashes damage the car as in vanilla.
[*] [b]Cheating clients in a seat[/b]: someone may briefly get into a seat; the server notices within about a second and acts on it. Admins choose "Log and warn" or "Remove from vehicle" in the sandbox option "Unauthorized occupant response"; either way it's written to the audit log and that player is warned.
[*] [b]Containers[/b]: whether they're listed is decided on the player's side, so a modified client may still take items from them, the same as vanilla locked cars; opening and closing the trunk door is still blocked by the server.
[*] [b]Attack notices[/b]: reported to the server by the attacker's own game, so a modified client can skip them and no notice appears; damage guard itself runs on the server and isn't affected.
[*] [b]Server-side[/b]: every decision is made on the server; clients only receive data they're allowed to see.
[/list]
=== ❓ FAQ
[h3]My character died. Is the car still mine?[/h3]
[list]
[*] Yes. Claims belong to your account, not your character.
[/list]
[h3]Are crashes, zombies or gunfire covered?[/h3]
[list]
[*] It depends on the server's damage guard setting (see "Damage guard"). With damage guard, weapons can't damage your car while no one is inside, and damage is repaired automatically.
[*] While someone is inside (for example while driving), weapons, zombies and crashes work as in vanilla.
[*] Cars without damage guard take damage as in vanilla; you're still told who hit your car.
[/list]
[h3]I'm an admin. Why can't I open other players' cars?[/h3]
[list]
[*] By default admins are blocked like any other player.
[*] Turn on "Override: use any vehicle" in the Admin tab of the fleet window; every use is logged.
[/list]
[h3]Does it work without MiniMap?[/h3]
[list]
[*] Yes. MiniMap only shows your cars on the map; claiming, protection, sharing and the fleet window all work without it.
[/list]
[h3]The server runs Vehicle Repair Overhaul. Can other players salvage or repair my car?[/h3]
[list]
[*] No. Its "Salvage Vehicle" option can't remove a car someone else has claimed.
[*] Its repairs (including engine rebuild, heater and lightbar) need the Repair permission you share; taking parts off already needs Salvage.
[*] To salvage your own claimed car, unclaim it first.
[/list]
[h3]Can my friends see where my car is?[/h3]
[list]
[*] Only people you gave the Location permission. By default nobody can.
[/list]
[h3]I lost my car. What now?[/h3]
[list]
[*] Check where it was last seen in the fleet window.
[*] If it's really gone, press "Unclaim lost vehicle"; the claim is released after a waiting period so you can claim another car.
[*] For a car imported from the old mod that never moved over, press "Unclaim vehicle" directly.
[/list]
[h3]What happens to my cars if I stop playing for a while?[/h3]
[list]
[*] After the number of days the server sets (30 by default) without logging in, your cars are unclaimed and others can claim them.
[*] Vehicle details in the fleet window show the "Kept until" date; time the server is down doesn't count.
[/list]
[h3]I need more claim slots. What can I do?[/h3]
[list]
[*] Ask the server admins to raise your limit.
[*] If the server runs Economy and sells slots, you can also buy or rent them from "Claim slots" in the fleet window.
[*] Guard slots work the same way from "Guard slots" in a car's details.
[/list]
[h3]Does it work in single player?[/h3]
[list]
[*] Yes, but it's made for multiplayer; the second split-screen player isn't supported.
[/list]
=== 💬 Feedback
[list]
[*] [b][url=https://discord.gg/Gur2V67]Discord[/url][/b]: please include
[list]
[*] what happened
[*] what you were doing at the time
[*] single player or multiplayer
[/list]
[/list]
