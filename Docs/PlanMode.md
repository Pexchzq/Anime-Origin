# Anime Origin — Mode Plan

ไฟล์นี้ใช้วางแผนพฤติกรรมของแต่ละโหมดก่อนเริ่มเขียนโค้ดจริง เพื่อไม่ให้ logic,
remote paths และค่าคอนฟิกปะปนกัน รายละเอียดในไฟล์นี้ยังไม่ถือว่าเป็นพฤติกรรมที่
นำไปใช้งานแล้วจนกว่าจะมีการสร้างและทดสอบ implementation แยกต่างหาก

## Mode: Fast Gems

สถานะ: implementation แยกความรับผิดชอบแล้ว เนื้อหา Phase 1 ด้านล่างเก็บไว้เป็น
ประวัติการออกแบบเท่านั้น ไม่ใช่ลำดับรันปัจจุบัน

ลำดับปัจจุบัน:

```text
FastMode.lua
  -> เคลมรางวัลทุกบัญชี
  -> เฉพาะ TotalSummons = 0 จึงสุ่มได้สูงสุด 10 ชุด

main.lua
  -> Normal Act แรกใน WestCity 1-6 ที่ยังไม่ผ่าน
  -> เมื่อผ่านครบแต่เลเวล < 15 ให้ Replay WestCity Act 1 Hard
  -> เมื่อเลเวล >= 15 ให้เข้า WestCity Infinite Hard
  -> Infinite ได้สัญญาณ Wave 20 ให้ RestartGame

AutoPlay.lua
  -> เลือกทีม วาง และอัปเกรดยูนิตภายในแต่ละแมตช์
```

ทุก transition ของ `main.lua` ต้องมีหลักฐานจาก `AfterMapSelect`, `TeleportGui`,
`OnTeleport`, `UpdateClientGame`, `StartWaveVote` หรือ MatchRuntime ตามชนิด action;
การเรียก `FireServer` อย่างเดียวไม่ถือว่าสำเร็จ

### เป้าหมาย

- เริ่มจากบัญชีใหม่ที่ไม่มีเพชร เลเวล หรือยูนิตพร้อมใช้งาน
- ใช้โค้ดรับเพชรเริ่มต้น
- ใช้เพชรเริ่มต้นสุ่มยูนิตจนไม่พอสุ่มต่อ
- เลือกและสวมใส่ยูนิตระดับ Legendary ขึ้นไปจำนวน 3 ตัว
- เลือกด่าน Story, WestCity, Act 1, Normal และเริ่มด่าน

### ลำดับการทำงาน

```text
[เข้า Lobby]
     |
     v
[Redeem Code]
     |
     v
[อ่านจำนวนเพชรปัจจุบัน]
     |
     v
<เพชรยังพอสุ่มหรือไม่?> -- ไม่พอ --> [อ่าน Inventory]
     |                                   |
    พอ                                   v
     |                            [กรองระดับ Regent+]
     v                                   |
[สุ่มตู้ Standard]                       v
     |                            <พบอย่างน้อย 3 ตัว?>
     +---------- วนกลับ ----------+      |
                                      ใช่|ไม่ใช่
                                         |  +--> [หยุดพร้อมแจ้งเหตุผล]
                                         v
                               [ถอดยูนิตที่ใส่อยู่ทั้งหมด]
                                         |
                                         v
                               [สวม Regent+ จำนวน 3 ตัว]
                                         |
                                         v
                       [เลือก Story / WestCity / Act 1 / Normal]
                                         |
                                         v
                                  [กดเริ่มด่าน]
```

#### Workflow แบบสถานะ

1. `WAIT_FOR_LOBBY`
   - รอจน Lobby remotes และข้อมูลผู้เล่นพร้อมใช้งาน
2. `REDEEM_STARTER_CODES`
   - ใส่โค้ดเริ่มต้นจาก Config ทีละรายการ
   - ต้องบันทึกว่าโค้ดใดสำเร็จ ใช้แล้ว หรือใช้ไม่ได้ เพื่อไม่วนยิงซ้ำ
3. `READ_STARTING_GEMS`
   - อ่านยอดก่อน redeem และยอดหลัง redeem จาก runtime
   - งบสุ่มเท่ากับ `ยอดหลัง redeem - ยอดก่อน redeem` เท่านั้น
4. `SUMMON_UNTIL_EXHAUSTED`
   - สุ่มตู้ `Standard`
   - ตรวจเพชรใหม่หลังการสุ่มแต่ละรอบ
   - สุ่มครั้งละ 10 ใช้ 500 Gems
   - ทำซ้ำเฉพาะจำนวนรอบที่งบจาก redeem จ่ายได้
   - ห้ามแตะ Gems เดิมหรือ Gems ที่ผู้ใช้ฟาร์มไว้ก่อนเริ่ม workflow
5. `READ_INVENTORY`
   - อ่านรายการยูนิตจริงจากกระเป๋า พร้อม UUID และระดับความหายาก
6. `SELECT_REGENT_OR_HIGHER`
   - กรองยูนิตระดับ Legendary, Mythic หรือ Secret
   - เลือกสูงสุด 3 ตัวโดยไม่ใช้ UUID แบบฟิก
   - หากมีน้อยกว่า 3 ตัว ให้หยุดและรายงานแทนการใส่ยูนิตผิดระดับ
7. `EQUIP_TEAM`
   - ถอดยูนิตทั้งหมดก่อนหนึ่งครั้ง
   - ใส่ยูนิตที่เลือกตาม UUID ทีละตัวให้ครบ 3 ตัว
   - อ่าน loadout กลับมายืนยันก่อนทำขั้นตอนต่อไป
8. `SELECT_FIRST_STAGE`
   - ส่งค่า `Story`, `WestCity`, `"1"`, `Normal`
   - ค่า Act เป็น string ตามรีโมตที่จับได้
9. `START_STAGE`
   - เรียกรีโมตกดเริ่มเมื่อ selection และทีมได้รับการยืนยันแล้ว
10. `PHASE_1_COMPLETE`
   - สิ้นสุดขอบเขตของแผนระยะนี้หลังคำสั่งเริ่มด่านสำเร็จ

### รีโมตที่ต้องใช้

- มีแล้ว: `use_in_lobby.redeem_code`
- มีแล้ว: `use_in_lobby.summon_standard_ten`
- มีแล้ว: `cross_remote.unequip_all_towers`
- มีแล้ว: `cross_remote.equip_tower`
- มีแล้ว: `use_in_lobby.start_map_selection`
- มีแล้ว: อ่าน Gems จาก runtime PlayerData
- มีแล้ว: อ่าน Inventory UUID และ rarity จาก runtime ครบ 50/50
- มีแล้ว: อ่าน loadout จาก `PlayerData.EquippedTowers` และจำนวนสล็อตจาก `MaxTowerSlot`
- มีแล้ว: รีโมตกดเริ่ม `MapSelectRemote:FireServer("StartTeleport")`

### คอนฟิกที่ผู้ใช้ปรับได้

- `redeemCodes`: รายการโค้ดเริ่มต้น
- `summonBanner`: ค่าเริ่มต้น `Standard`
- `summonBatchSize`: ค่าเริ่มต้น `10`
- `minimumRarity`: `Legendary`
- `summonBatchCost`: `500`
- `spendOnlyRedeemedGems`: `true`
- `teamSize`: ค่าเริ่มต้น `3`
- `mode`: `Story`
- `world`: `WestCity`
- `act`: `"1"`
- `difficulty`: `Normal`

### เงื่อนไขเริ่มและหยุด

- เริ่ม: ผู้เล่นเข้า Lobby และข้อมูลบัญชีพร้อมอ่าน
- จบระยะที่ 1: ทีม 3 ตัวได้รับการยืนยัน เลือกด่านถูกต้อง และส่งคำสั่งเริ่มด่านสำเร็จ
- หยุดแบบปลอดภัย: Lobby ไม่พร้อม, redeem ล้มเหลวทั้งหมด, อ่านเพชรไม่ได้,
  อ่าน Inventory ไม่ได้, Regent+ ไม่ครบ 3 ตัว, equip ไม่ครบ หรือยังไม่มีรีโมตกดเริ่ม

### กรณีผิดพลาดและการกู้คืน

- ทุกขั้นตอนต้องอ่านสถานะจริงก่อนและหลังส่งรีโมต ไม่ตัดสินความสำเร็จจากการไม่เกิด Error
- จำกัดจำนวนครั้งและเวลารอของแต่ละสถานะ เพื่อป้องกันลูปไม่จบ
- ห้ามสุ่มต่อเมื่ออ่านยอดเพชรไม่ได้ เพราะไม่สามารถยืนยันเงื่อนไขหยุดได้
- ห้ามใช้ UUID, rarity หรือจำนวนเพชรแบบฟิก
- ราคาสุ่ม 10 ครั้งยืนยันแล้วว่า 500 Gems และเก็บไว้ใน Config
- หาก rejoin ให้เริ่มตรวจสถานะใหม่ ไม่ยิง redeem หรือ unequip ซ้ำโดยไม่จำเป็น

## Mode: Fast Gems — In-game phase

### Implemented: pre-match setup

- `InGameSettings.lua` owns settings and game speed. Toggle-only settings are
  compared with authoritative runtime state before `SetSetting` is fired.
- `AutoPlay.lua` owns team selection and later placement/upgrade logic; settings
  remotes must never be added to this file.
- Damage units are ranked using the highest `StageStats` level after applying
  the owned UUID Grade multipliers. `DPS = Damage / Cooldown`; Range breaks ties.
- The desired slot order is three damage units, LEO in slot 4 (or damage fallback),
  then the next two damage units.
- Slots 4–6 are detected from server acceptance in `EquippedTowers`, not from UI
  lock cards or a fixed account-level assumption.
- Every unequip/equip action is followed by a runtime verification before the
  next action is allowed.
- Both scripts remain armed across match boundaries: InGameSettings restores the
  confirmed `Two = 1.4` runtime speed multiplier after a reset, while AutoPlay
  listens to replicated lifecycle state/server events and re-applies the team.
- Stop controls are `AnimeOriginInGameSettings.stop()` and
  `AnimeOriginAutoPlay.stop()` when testing needs to end without rejoining.

### Verified live-match evidence

- The no-hook V3 run observed `StartWaveVote`, `EndWaveVote`, and
  `<MatchRuntime>.GameStarted` changing from `false` to `true`; direct readying can
  therefore be verified without reading or clicking the Confirm UI.
- Both placement and upgrade use
  `ReplicatedStorage.LobbyRemotes.TowerHandlerRemotes.TowerHandlerFunction`.
- Placement is verified by `TowerHandlerRemote` action `CreateNewTower`, whose
  table includes placed UUID, inventory UUID, team slot, position and StageStats.
- Upgrade is verified by `TowerHandlerRemote` action `UpdateTower`, whose UUID
  and patch prove that `Stage` increased.
- The runtime callbacks read the server-replicated `Money` attribute before an
  action. AutoPlay uses the same source only as a budget gate and still requires
  the server response as final proof.
- WestCity Ground/Hill points captured from real server responses are enabled in
  `Config.lua`. Every other world still needs its own configured point set.

### Implemented: focused discovery pass

- `Probes/InGameDiscoveryProbe.lua` V3 is the single read-only capture pass for all four
  pending items. It installs no `__namecall` or function hook. It discovers
  action functions/constants and the ReplicatedStorage remote inventory, then
  correlates incoming server events with non-UI ValueBase/getgc/Workspace changes.
- Hooking is intentionally disabled: two clean sessions captured
  `WaveVote, true` while the ready UI and `<MatchRuntime>.GameStarted` remained
  unchanged. Server/runtime state changes are the success proof instead.
- Run it after stage loading but before Confirm, then Confirm once, place one
  damage unit normally, upgrade that same unit at least twice, and call
  `AnimeOriginInGameDiscovery.stop()`.
- Chronological evidence is saved to
  `AnimeOrigin/InGameDiscoveryTrace.jsonl`; the bounded report is saved to
  `AnimeOrigin/InGameDiscovery_latest.json` in the executor workspace.
- Production `placementEnabled` and `upgradeEnabled` are now true for WestCity.
  Failed points receive a short retry cooldown; they are never accepted as valid
  unless `CreateNewTower` arrives.
