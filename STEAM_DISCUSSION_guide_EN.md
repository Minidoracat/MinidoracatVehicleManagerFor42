<!-- Steam 討論區貼文稿源（English）；簡介只放摘要，詳細內容以本串為準 -->
<!-- 討論串網址：https://steamcommunity.com/workshop/filedetails/discussion/3813972279/586187800873910928/ -->
<!-- 標題：📖 Vehicle Manager Guide: Claims, Protection & Fleet -->

[b]繁體中文版：[/b][url=https://steamcommunity.com/workshop/filedetails/discussion/3813972279/586187800873910915/]Vehicle Manager 完整說明：車輛綁定、保護與車隊[/url]

Vehicle Manager lets you claim a car to your account so other players can no longer drive it, siphon its fuel, strip its parts or tow it away. You can share it with friends or your faction and manage your cars from a fleet window and the minimap. This thread covers every feature in detail, the admin tools and common questions.

[h2]🚀 Quick start[/h2]
[olist]
[*] The server enables this mod and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3789836701]Minidoracat UI Library[/url]; add [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3763913359]Minidoracat MiniMap[/url] to see your cars on the map, and [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125]Minidoracat Economy[/url] to let players buy claim slots
[*] Right-click next to a car, choose "Vehicle Manager → Claim vehicle", and confirm what the protection covers
[*] Open the fleet window with the steering wheel icon in the family toolbar to view, rename or share your cars
[/olist]

[h2]🔒 Claiming and protection[/h2]
[list]
[*] Claims belong to your account, so you keep your cars when your character dies; the server sets how many cars each player can claim
[*] Players without permission cannot: open or close doors, unlock, get in, start the engine, add or siphon fuel, deflate tires, install or remove parts, repair, smash windows, tow, install/remove AutoDrive GPS and autopilot modules, or take the headphones out of the car radio
[*] When blocked they see "This vehicle is protected by its owner" and the car stays as it was
[*] [b]Parked guard[/b]: while no owner or shared player is inside, weapons (melee or guns) cannot damage a claimed car; about every 10 seconds the server repairs damage, puts back broken windows and clears the broken glass. It pauses while someone is inside or the car is being towed, and resumes when they get out. If someone attacks your car while you are online, you get a notice
[*] Containers follow permissions: the trunk, truck bed, trailers and modded cargo boxes need the "trunk" permission, seats and the glovebox need "ride"; without permission they do not show up in the inventory
[*] Owners can unlock, open doors (without the alarm) and start the car without a physical key (servers can turn this off)
[/list]

[h2]🤝 Sharing[/h2]
[list]
[*] Share with specific players or your faction and pick each permission: ride, drive, trunk, fuel, install/repair, remove parts, tow, see location
[*] [b]Share with everyone[/b]: any player can use what you tick, limited to ride, drive, trunk, fuel and install/repair (remove parts, tow and see location cannot be public); other players see what everyone can do in the car's right-click menu
[*] Private by default; nothing is shared automatically. Current shares are listed one per row, and one click stops each
[*] Only the owner can rename, share, unclaim or transfer, and these rights cannot be shared
[*] If the faction is renamed, disbanded or gets a new leader, faction sharing pauses until the owner confirms again
[/list]

[h2]🗂️ Fleet window[/h2]
[list]
[*] Open it with the steering wheel icon in the family toolbar; press "." to expand the toolbar when it is collapsed
[*] See your cars, cars shared with you and where they were last seen; click the coordinates in vehicle details to copy them and paste them to others
[*] Rename, share, transfer or unclaim; when the server uses guard slots, turn on "Parked guard" for each car in its details, which also show the guard status and how many guard slots you use
[*] [b]Report lost[/b]: the claim is released after a waiting period; the car stays protected meanwhile, and if the server sees it again soon the release is cancelled
[*] [b]Kept until[/b]: if the owner does not log in for the number of days the server sets (30 by default), their cars are unclaimed automatically. Vehicle details show the date, which moves forward every time you play; time the server is down does not count
[/list]

[h2]🗺️ Minimap tracking (optional)[/h2]
With Minidoracat MiniMap installed, your cars and shared cars you may "see location" of show on the minimap and world map. Nobody else can see them. Each car can have its own map icon, color and size; these settings are stored only on your computer. If car names clutter the minimap, untick "Show car names on the minimap" under Vehicle Manager in the MiniMap settings (the minimap's gear) to keep only the icons; the world map still shows names.

[h2]💰 Paid slots (optional)[/h2]
[list]
[*] On dedicated multiplayer servers that also run [url=https://steamcommunity.com/sharedfiles/filedetails/?id=3801482125]Minidoracat Economy[/url], the owner can sell extra claim slots and parked guard slots for in-game money, to buy outright or to rent; nothing is sold by default
[*] Press "Claim slots" in the fleet window (guard slots: "Guard slots" in a car's details): buy several slots at once, or rent them. Each rental is separate, with its own slot count and end date, and is renewed or set to auto-renew on its own
[*] Before you pay you see the quantity, price, your balance before and after, and how many cars you can claim (or guard) afterwards; the slots work the moment you pay
[*] If the rent, currency or period changes, auto-renew pauses until you accept the new terms
[*] [b]When a rented claim slot ends[/b]: a grace period starts (set by the server owner), and slots in grace cannot be used for new claims. Cars over your limit are locked, newest first: neither you nor shared players can use them, and renewing or unclaiming other cars unlocks them right away. If you are still over the limit when the grace period ends, the locked cars are unclaimed. You get a notice at every step, and the fleet window shows when the grace period ends
[*] When a rented guard slot ends, cars over your guard slots only lose parked guard; they stay yours
[*] A refund only lowers how many new cars you can claim; cars you already claimed stay protected
[*] Server owners can edit the settings files on the server, or admins can open "Paid claim slot settings" or "Paid guard slot settings" from the Admin tab or the slots window to change prices, currencies, limits, periods and grace hours; each change needs a reason and is logged
[/list]

[h2]🛠️ Admin tools[/h2]
[list]
[*] The Admin tab of the fleet window lists players with their claimed count and limit; click a player to expand their cars, adjust their basic slots, or unclaim a problem vehicle as admin. Player details show when they were last online, and vehicle details have "Teleport to vehicle" to go to where the car was last seen
[*] The Admin tab also edits the default slots for all players, the auto-unclaim days (0 = never), the parked guard mode (off / all claimed vehicles / by guard slots) and the guard slots per player; these are the same settings as the sandbox options. With guard slots you can also set guard slots for one player
[*] By default admins are blocked like any other player. To use someone else's car, turn on "Override: use any vehicle" in the Admin tab: every use is logged, the steering wheel icon in the family toolbar gets a red frame while it is on, and it turns off automatically when you log in again or the server restarts
[*] In vanilla, split-screen players type their own name and the server does not verify it, while vanilla safehouses and factions trust names, so other players can be impersonated. If your server does not need split-screen, set AllowCoop to false in the server settings (this mod already gives split-screen players no vehicle access)
[/list]

[h2]⚠️ What is protected[/h2]
[list]
[*] Normal player actions are protected. Cars with parked guard resist weapons while parked; while someone is inside, while being towed, or without parked guard, weapons, zombies and crashes damage cars as in vanilla (zombies do not attack empty parked cars, and other players driving into a parked car do not damage it)
[*] Parked guard does not refill fuel, battery charge or cargo; damage a cheating client deals directly, bypassing weapons, is repaired at the next check (within about 10 seconds)
[*] Someone using a cheating client may briefly get into a seat; the server notices within about a second and acts on it (admins choose between logging only or removing them from the car)
[*] Whether a car's containers are listed is decided on the player's side, so a modified client may still take items from them, the same as vanilla locked cars; opening and closing the trunk door is still blocked by the server
[*] Every decision is made on the server; clients only receive data they are allowed to see
[/list]

[h2]🔁 Moving from Mysterious Vehicle Claim Key (admins)[/h2]
[olist]
[*] Make a full backup of the save (including the world save folder)
[*] Add this mod to the server (MVCK can stay for now) and start the server
[*] Press "Import all claims from MVCK" in the Admin tab of the fleet window: loaded vehicles move over at once, the rest the next time they load (vehicles still on a trailer move over when unloaded); the window shows how many were imported, bound now and still waiting
[*] You can press it again; it only picks up claims made in MVCK since, without duplicates, and never deletes MVCK data
[*] Once you are happy, remove MVCK from the server yourself. While both mods run, both protections apply, and vehicles claimed in MVCK cannot be claimed with this mod; the import moves them to their owners
[/olist]
MVCK public permissions become "Share with everyone": allowing everyone to ride, drive, open the trunk, siphon fuel or inflate tires maps to ride, drive, trunk, fuel and install/repair. Other public permissions (taking parts, deflating, smashing windows and so on) and per-player permissions are not imported, so owners need to share again. Pending imports whose vehicle never shows up are cleared after the number of days set in sandbox options (30 by default).

[h2]❓ FAQ[/h2]
[b]Q: My character died. Is the car still mine?[/b]
A: Yes. Claims belong to your account, not your character.

[b]Q: Are crashes, zombies or gunfire covered?[/b]
A: It depends on the server's parked guard setting. With parked guard, weapons cannot damage your car while no one is inside, and damage is repaired automatically; while someone is inside (for example while driving), weapons, zombies and crashes work as in vanilla. With parked guard off, or on a car without it, damage works as in vanilla.

[b]Q: I am an admin. Why can't I open other players' cars?[/b]
A: By default admins are blocked like any other player. Turn on "Override: use any vehicle" in the Admin tab of the fleet window; every use is logged.

[b]Q: Does it work without MiniMap?[/b]
A: Yes. MiniMap only shows your cars on the map; claiming, protection, sharing and the fleet window all work without it.

[b]Q: Can my friends see where my car is?[/b]
A: Only people you gave the "see location" permission. By default nobody can.

[b]Q: I lost my car. What now?[/b]
A: Check where it was last seen in the fleet window. If it is really gone, press "Report lost"; the claim is released after a waiting period so you can claim another car.

[b]Q: What happens to my cars if I stop playing for a while?[/b]
A: After the number of days the server sets (30 by default) without logging in, your cars are unclaimed and others can claim them. Vehicle details in the fleet window show the "kept until" date; time the server is down does not count.

[b]Q: I need more claim slots. What can I do?[/b]
A: Ask the server admins to raise your limit. If the server runs Economy and sells slots, you can also buy or rent them from "Claim slots" in the fleet window. Guard slots work the same way from "Guard slots" in a car's details.

[b]Q: Does it work in singleplayer?[/b]
A: Yes, but it is made for multiplayer; the second split-screen player is not supported.

[h2]💬 Reporting problems[/h2]
Please report issues on [url=https://discord.gg/Gur2V67]Discord[/url] with what happened, what you were doing at the time, and whether it was singleplayer or multiplayer.
