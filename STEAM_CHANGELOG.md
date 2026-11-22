[h1]Minidoracat Vehicle Manager for B42 42.22.2-0.15.0[/h1]
[i]2026-11-22[/i]

[b]English summary[/b]
[list]
[*] Locking or unlocking a door now needs the permission for that door, the same as opening it: seat doors need Ride, the trunk needs Trunk, the hood needs Repair or Salvage. Locking all doors from inside still needs Ride.
[*] The virtual key follows the same permissions: players with Trunk can unlock the trunk without a key, and players with Repair or Salvage can unlock and open the hood. The "Unlock (virtual key)" option only lists doors you can unlock.
[*] Adjusting the headlight angle on someone else's claimed vehicle now needs Repair.
[*] Single player: when an action is blocked, the actions queued after it no longer run, and blocked refueling or siphoning stops right away.
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]鎖、解鎖一扇門改看那扇門的權限[/b]：之前別人綁定的車，只要有「搭乘」權限就能鎖、解鎖引擎蓋和後車廂；反過來，只有「安裝修理」權限、沒帶鑰匙的人解不開引擎蓋，用「車輛資訊」開引擎蓋時卡在解鎖那一步。現在鎖、解鎖和開關門一樣看門：座位的車門要「搭乘」，後車廂要「後車廂」，引擎蓋要「安裝修理」或「拆零件」。坐在車上整車上鎖照舊只要「搭乘」，單人用手把操作時也不會連帶鎖上或解開後車廂。車主自己與沒綁定的車照常。
[*] [b]免鑰匙（虛擬鑰匙）照上面的權限[/b]：有「後車廂」權限的人不帶鑰匙也能解開後車廂；有「安裝修理」或「拆零件」權限的人能解開並打開引擎蓋。車輛右鍵的「解鎖（虛擬鑰匙）」只列出你解得開的門。單人遊戲沒帶鑰匙、站在車外的車主，之前用虛擬鑰匙解不開車門，現在解得開。
[*] [b]調整頭燈角度要「安裝修理」權限[/b]：之前別人綁定的車誰都能調。
[/list]

[h3]🔧 修正[/h3]
[list]
[*] [b]單人遊戲被擋下的動作，後面排的動作不再照做[/b]：之前被擋下開引擎蓋後，「車輛資訊」視窗照樣打開、又排一次開蓋，提示跳兩次。現在被擋下就停在那裡，提示一次。被擋下的加油、抽油也會立刻停下，不用等時間跑完。
[/list]
