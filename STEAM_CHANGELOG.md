[h1]Minidoracat Vehicle Manager for B42 42.22.2-0.12.0[/h1]
[i]2026-11-16[/i]

[b]English summary[/b]
[list]
[*] New: when a rented claim slot ends and you are still over your slot limit, the locked car is no longer released right away. It is kept for 7 days (server owners can set 0–365 days in the sandbox option "Keep vehicles after a rental ends (days)"; 0 = release right after the grace period, like before). While kept, the car is still yours, still locked and protected, and the fleet window shows the keep deadline. Rent again or release another car to unlock it; it is released only when the keep period ends. You get a notice when the car is kept.
[*] New for admins: when you change the rent price, currency or days in "Paid claim slot settings" or "Paid guard slot settings", or stop renting or turn off auto-renew, the confirm box now says how many rentals will have auto-renew paused and how many players that affects. After applying, the window shows how many were actually paused.
[*] The default grace period for paid slots is now 3 days (72 hours) instead of 24 hours. This only affects worlds connecting to the economy system for the first time; worlds that already did keep their current value. Admins can change it in the paid slot settings.
[*] Grace period notices and the fleet window no longer say "then released", because a keep period follows the grace period.
[*] When several rented slots end at different times, extra locked cars from the first one to end also go into the keep period instead of unlocking automatically. While a renewal is still waiting for the economy system to confirm, cars stay locked instead of unlocking for a moment.
[*] Clearer wording about paused auto-renew in the slots window and the settings: it only resumes if the plan is changed back before that rental's grace period ends; after that the rental is no longer renewed.
[/list]

[h3]✨ 新增[/h3]
[list]
[*] [b]租用名額結束後，車先保留一段時間才解除綁定[/b]：租用的綁定名額寬限結束、仍超出名額時，鎖定的車不再當場解除綁定，而是保留 7 天（服主可在沙盒選項「租用名額結束後保留天數」改成 0～365 天，0＝跟以前一樣寬限一過就解除）。保留期間車照樣是你的、照樣鎖定和受保護，車隊視窗寫著保留到什麼時候；重新租用或解除其他車就解鎖，期滿才解除綁定。進入保留時會收到通知。
[*] [b]管理員改付費名額方案前，先知道會影響幾位玩家[/b]：在遊戲內的付費名額設定改租金、幣別、天數，或停止租用、不再允許自動續租時，如果有玩家的自動續租會因此暫停，套用確認框第一行會寫出會暫停幾張租約、涉及幾位玩家，確認鈕也改成紅色；套用後視窗會顯示實際暫停了幾張。伺服器的 Minidoracat Economy 是舊版時照舊直接確認。
[/list]

[h3]🔄 變更[/h3]
[list]
[*] [b]付費名額的預設寬限從 24 小時改成 3 天（72 小時）[/b]：只影響第一次接上經濟系統的世界（新世界，或之前沒裝經濟系統）。已經接上過經濟系統的世界照原本的值（之前的預設是 24 小時），就算從沒改過付費頁也一樣；要改請到付費名額設定改寬限。改寬限不會暫停玩家的自動續租，已經在跑的那一期照購買當時的寬限，下一期才換新值。
[*] [b]寬限期的通知與車隊視窗不再寫「之後解除綁定」[/b]：寬限結束後還有保留期，改成只寫寬限到什麼時候。
[*] [b]多張租用名額錯開結束時[/b]，先結束那張多出來的鎖定車也會進入保留期，不再自動解鎖；續租還在等經濟系統確認時也維持鎖定，不再暫時解鎖。
[*] [b]自動續租暫停的說明改得更準確[/b]：名額視窗與付費名額設定原本寫「改回就恢復」，現在寫清楚只有在租約寬限結束前改回才會恢復，過了寬限那張租約就不再續租。
[/list]
