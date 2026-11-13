[h1]Minidoracat Vehicle Manager for B42 42.22.2-0.11.3[/h1]
[i]2026-11-14[/i]

[b]English summary[/b]
[list]
[*] Fixed: if you lost access while sitting in someone's claimed vehicle (share removed, faction share paused, rental expired), you could not get out. You can now always open the door of your own seat and exit.
[*] Fixed: the inventory window kept throwing errors in that same situation.
[*] Changed: on servers that also run a mod that makes physical car keys (Minidoracat AnyCar), only the owner can make a key for a claimed vehicle. Hotwiring still only needs the Drive permission.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]失去權限時人還坐在車上，下不了車[/b]：你坐在別人綁定的車上時，如果車主收回分享、陣營分享被暫停，或你坐著的車剛被別人綁定，按下車沒有反應，只能等車主開門或管理員幫忙。租用名額到期被鎖住的車，車主自己坐在車上也一樣。現在坐在車上的人一定開得了自己座位那扇門，可以照常下車。別的座位的門、引擎蓋、後車廂照舊要權限；下車後不能再關上那扇門，門會留著開。
[*] [b]同一個狀況下畫面右下角一直跳錯誤[/b]：失去權限時人還坐在車上，物品欄會不斷出錯。現在不會了：自己坐著的那個座位照常列在物品欄，其他座位、置物箱、後車廂照舊要權限才看得到。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]配鑰匙需要管理權限[/b]：伺服器同時裝了能替車配出實體鑰匙的 MOD（Minidoracat AnyCar 的配車鑰匙）時，別人綁定的車只有車主（或開啟越權的管理員）能配鑰匙；被分享「駕駛」的人選配鑰匙時會看到「只有車主能替這台車配鑰匙」。原版的熱線，以及拆除短接，照舊只要「駕駛」權限。沒裝這類 MOD 的伺服器沒有影響。
[/list]
