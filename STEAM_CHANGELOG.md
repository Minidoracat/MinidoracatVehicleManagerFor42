[h1]Minidoracat Vehicle Manager for B42 42.22.2-0.14.0[/h1]
[i]2026-11-16[/i]

[b]English summary[/b]
[list]
[*] New: Project RV Interior support. On servers that run both mods, entering the interior room of a claimed vehicle now needs the Trunk permission from its owner.
[*] Players with only Ride or Drive can't enter either, even while sitting in the vehicle; they see the "this vehicle is claimed" notice.
[*] Owners, players with Trunk, and unclaimed vehicles work as before.
[*] Someone already inside the room without Trunk (share taken away, vehicle transferred, or vehicle locked by a rental slot) is asked to leave by the server within about a second and returns to the vehicle (or to their seat, if they entered from one). After this update, the server starts doing this for a room once someone has entered it from that vehicle.
[*] Players are only moved out when the server option AntiCheatSpeed is 3 (log only) or 4 (off). With kick (the default) or ban, the game's anti-cheat would punish the moved player, because Project RV Interior moves players instantly. Split-screen players are not moved out; sleeping players are moved out after they wake up.
[*] This is not a server-side guarantee: a player with a modified client may still get into or stay in a room.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]支援 Project RV Interior：別人綁定車輛的車內房間要「後車廂」權限[/b]：伺服器同時裝了 Project RV Interior 時，之前沒有權限的人也能從別人綁定的車進到車內房間。現在要車主分享「後車廂」權限才進得去；只有「搭乘」或「駕駛」權限的人也一樣（包括已經坐在車上的），被擋時會看到這台車已被綁定的提示。車主自己、有「後車廂」權限的人和沒綁定的車照常。已經在房間裡、沒有權限的人（分享被收回、車轉讓給別人、車被租用名額鎖定）也會被伺服器請出去，約一秒內回到車旁（從座位進去的人回到原座位）。請出的條件：更新到這版後，要有人從這台車進過一次房間，伺服器才認得這間房；伺服器的 AntiCheatSpeed 要設成 3（只記錄）或 4（關閉），設成踢出（預設值）或封鎖時不請出，因為 Project RV Interior 的進出是瞬間移動，被請出的人會被遊戲的反作弊踢掉；用分割畫面遊玩的玩家不請出，睡著的人等醒來才請。這不是伺服器保證：改過客戶端的人仍可能進到或留在房間。
[/list]
