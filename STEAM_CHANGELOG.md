[h1]Minidoracat Vehicle Manager for B42 42.22.2-0.11.4[/h1]
[i]2026-11-14[/i]

[b]English summary[/b]
[list]
[*] Fixed: after a server crash or forced shutdown in the middle of saving, some vehicle claims could silently disappear on the next start (large servers with many claimed vehicles). All ownership data is now read back.
[*] Fixed: if ownership data files are damaged or missing, the server no longer starts as if nothing happened. It refuses ownership changes, keeps protecting the claims it can still read, and writes the reason and restore steps to the server log.
[*] No action needed to upgrade: existing servers keep all claims, shares and slots.
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]伺服器存檔寫到一半中斷後重開，部分綁定消失[/b]：伺服器在存檔途中當機、被強制關閉或磁碟滿之後重開，有些車會變回沒綁定，車主的綁定、分享與名額跟著不見，而且沒有任何提示。綁定很多車的大型伺服器才會遇到。現在重開時會把存檔裡所有的帳本檔都讀回來，這種情況下綁定不再消失。
[*] [b]帳本檔損壞時不再悄悄當成沒事[/b]：帳本有檔案損壞或不見時，以前照常開服，那些車直接變成沒綁定。現在伺服器會停止所有權變更（不能綁新車、改分享、解除綁定），並在伺服器紀錄寫明原因與還原步驟；還讀得到的綁定照常受保護。管理員照 GitHub 說明從同一份備份還原後恢復正常。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]升級不需要做任何事[/b]：現有伺服器更新後直接開服即可，綁定、分享與名額都保留。
[/list]
