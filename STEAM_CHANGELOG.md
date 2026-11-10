[h1]Minidoracat Vehicle Manager for B42 42.22.2-0.11.1[/h1]
[i]2026-11-10[/i]

[b]English summary[/b]
[list]
[*] Supports Project Zomboid 42.22.2. Nothing to change in your settings.
[*] Riding in a KI5 vehicle with CTIS (automatic tire inflation) no longer shows "This vehicle is claimed" again and again while the engine runs. Permissions are unchanged.
[*] Getting in or out of an armored KI5 vehicle no longer shows that message either.
[*] Taking the CD out of a car radio, or putting one in, now needs the Trunk permission, like the headphones.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]支援 Project Zomboid 42.22.2[/b]：已對照 42.22.2 的遊戲改動逐項檢查，並在 42.22.2 的多人伺服器重新測過綁定車的操作防護、防破壞、拖車裝卸、被拖車時自動解除拖曳、車上容器與玩家身分。功能照常運作，設定不用改；42.21 的伺服器也照常能用。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]坐在別人分享給你的 KI5 軍用車上，一直跳「這台車已被綁定…」[/b]：遊戲更新到 42.22 後，有自動補胎壓（CTIS）的 KI5 車在引擎發動、胎壓不足時，車上沒有「安裝與修理零件」權限的人每兩秒就跳一次紅字提示，自己什麼都沒按也一樣。現在不再跳提示。權限沒有變：沒有這個權限的人一樣不能改胎壓。
[*] [b]上下 KI5 裝甲車時跳「這台車已被綁定…」[/b]：有裝甲的 KI5 車在你上車、下車時會自動同步零件耐久；車上沒有「安裝與修理零件」權限的人每次上下車都跳紅字提示。現在上車、坐在車上、下車都不再跳；只有下車前一秒內裝甲剛吸收過傷害時，下車還會跳一則。權限沒有變：沒有這個權限的人一樣不能改零件耐久。
[*] [b]車上收音機的 CD 加強驗證[/b]：取出或放入車上收音機的 CD、錄影帶，現在和耳機一樣要「後車廂」權限；只被分享「搭乘」的人不能拿走。擺在地上或拿在手上的收音機不受影響。
[/list]
