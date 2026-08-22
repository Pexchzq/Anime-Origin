# Anime Origin

โปรเจกต์ถูกแยกตามหน้าที่เพื่อให้ไฟล์ที่ต้องรันจริงไม่ปะปนกับเครื่องมือค้นหาพาท

## ไฟล์หลัก

| ไฟล์ | หน้าที่ |
| --- | --- |
| `Config.lua` | คอนฟิกกลาง ต้องรันก่อนสคริปต์ที่อ่านการตั้งค่า |
| `FastMode.lua` | เคลมรางวัลและเควสทุกไอดี; เฉพาะบัญชีใหม่จึงสุ่มตาม Gems โดยยืนยัน `TotalSummons` และยอด Gems ทุกชุด |
| `UnitProgression.lua` | ล็อกยูนิตที่กำหนด จัดอันดับ Top 6 ย่อยตัวซ้ำ ซื้อ/ป้อน Food และเฉลี่ยเลเวล 1–3 ก่อน 4–6 |
| `InGameSettings.lua` | ซิงก์ Settings, Game Speed และ Summon Auto Sell จากค่าจริงใน PlayerData |
| `AutoPlay.lua` | เลือกทีม วาง และอัปเกรดยูนิตภายในด่าน |
| `main.lua` | เลือกเส้นทาง Fast Gems, เข้าประตู Story, เริ่มด่าน และจัดการ Next/Replay/Lobby/Infinite restart โดยยืนยันสัญญาณจากเซิร์ฟเวอร์ |
| `Optimizer.lua` | ลดเอฟเฟกต์/เรนเดอร์/เสียง/FPS, ล้าง transient End Screen/Reward popup หลังเซิร์ฟเวอร์ยืนยัน transition และวัดแนวโน้ม RAM/CPU/PlayerGui แบบ bounded |

## โฟลเดอร์

- `Probes/` — สคริปต์อ่านค่า ค้นหาพาท และ tracer สำหรับดีบัก ไม่ใช่ไฟล์รันปกติ
- `Registry/` — เอกสารพาทและรีโมตที่ยืนยันแล้ว ไม่มีการยิงรีโมต
- `Docs/` — แผนและหลักฐานการออกแบบ

## โพรบพิกัด

ต้องการบันทึกพิกัดตำแหน่งที่ตัวละครยืนอยู่ ให้ยืนตรงจุดนั้นแล้วรัน:

```lua
Probes/CurrentPositionProbe.lua
```

สคริปต์จะพิมพ์ `Vector3.new(...)` และบันทึกไฟล์ล่าสุดเป็น
`AnimeOrigin_CurrentPosition.json` กับ `AnimeOrigin_CurrentPosition.lua`
ส่วน `AnimeOrigin_PositionHistory.jsonl` จะเก็บประวัติเมื่อ executor รองรับ
`appendfile` โดยไม่ต้องเปิด UI ของเกม

## ลำดับรัน

ไฟล์หลักรองรับ MacSploit Auto-Execute แบบไม่รับประกันลำดับแล้ว: controller
ทุกตัวจะรอ `Config.lua` และ `Players.LocalPlayer` สูงสุด 30 วินาที แทนการจบทันที
หากถูก inject ก่อน Config ส่วน running guard ของ controller ที่เฝ้าระยะยาวจะผูก
กับ `game.JobId` เพื่อไม่ให้ flag จากล็อบบี้เก่าขวางการเริ่มใหม่หลังเทเลพอร์ต
หลังได้ Config แล้ว FastMode และ InGameSettings ยัง refresh `getgc(true)` ระหว่าง
รอ live PlayerData/รีโมตสูงสุดตาม `runtimeLoadTimeout` จึงไม่ใช้ snapshot ว่างจาก
ช่วง Loading เป็นผลล้มเหลวถาวร ส่วน AutoPlay จะคืน `IDLE_LOBBY` ในล็อบบี้ และ
เริ่มค้น `MatchRuntime` ใหม่เฉพาะ place ของด่านเท่านั้น

Bootstrap ในล็อบบี้:

```text
Config.lua
	├─ Optimizer.lua (ทำงานแยก ไม่เป็น bootstrap dependency)
  ├─ InGameSettings.lua (ซิงก์ Auto Sell ก่อนการสุ่ม และเฝ้า Game Speed ต่อ)
  ├─ FastMode.lua ──> UnitProgression.lua ──┐
  └─ main.lua (รอสัญญาณ) ──────────────────┴─> เริ่มเลือกด่านเมื่อทั้งคู่ COMPLETE
```

เริ่ม `InGameSettings.lua`, `FastMode.lua`, `UnitProgression.lua` และ `main.lua`
จากคนละ executor task ได้ แต่ `UnitProgression.lua` จะรอให้ FastMode สุ่มเสร็จก่อน
ถ่าย snapshot ของ Inventory เพื่อไม่จัดอันดับข้อมูลกลางการสุ่ม ทั้งสองไฟล์ส่งสถานะผ่าน
`AnimeOriginLifecycle.tasks` ส่วน `main.lua` จะรอเฉพาะตอนอยู่ล็อบบี้ หากตัวใด
`FAILED` จะไม่เข้าประตู Story และถ้ายังไม่รันจะขึ้น `PENDING` ในล็อกของ main
คอนฟิค `Config.main.bootstrapGate.timeout` กำหนดเวลารอสูงสุด

`main.lua` อ่าน `StoryProgress.WestCity` และเลเวลจริงโดยไม่เปิด UI แล้วเลือกตามลำดับ:

1. ด่าน Normal แรกใน Act 1–6 ที่ยังไม่ผ่าน
2. WestCity Act 1 Hard จนถึง `minimumInfiniteLevel`
3. WestCity Infinite Hard และสั่ง `RestartGame` ที่ `restartInfiniteAtWave`

ก่อนเลือกด่าน ตัวละครจะวาร์ปไปด้านนอกประตู Story แล้วเดินผ่านประตูจริง จากนั้น
`StartSelection` ต้องได้รับ `AfterMapSelect` ที่ตรงกัน และ `StartTeleport` ต้องได้รับ
`TeleportGui` หรือ `LocalPlayer.OnTeleport` จึงถือว่าสำเร็จ

`Config.unitProgression.dryRun = true` จะสร้างแผนอย่างเดียวใน
`AnimeOrigin/UnitProgression_<UserId>_latest.json` โดยไม่ซื้อ ไม่ย่อย และไม่ป้อน
Food หลังตรวจแผนแล้วจึงเปลี่ยนเป็น `false` เพื่อให้ทำงานจริง ทุก action จะหยุด
ทันทีถ้ายืนยันการเปลี่ยนแปลงจาก PlayerData ไม่ได้

ภายในด่าน:

```text
Config.lua -> Optimizer.lua + main.lua + InGameSettings.lua + AutoPlay.lua
```

ให้รันแต่ละ controller แยกกันโดยรัน `Config.lua` ก่อนเสมอ `main.lua` จะคืน
controller ทันทีและเฝ้าสัญญาณแมตช์ต่อเบื้องหลัง ส่วน `AutoPlay.lua` ดูแลทีม วาง
และอัปเกรดโดยอิสระ เมื่อเทเลพอร์ตไปเซิร์ฟเวอร์ใหม่ executor ต้อง auto-execute
`Config.lua`, `main.lua`, `InGameSettings.lua` และ `AutoPlay.lua` ใหม่; ไฟล์
`AnimeOrigin/MainRoute_<UserId>.json` จะทำให้ `main.lua` ต่อเส้นทางเดิมได้
FastMode กับ UnitProgression ที่ถูก Auto-Execute ใน place ของด่านจะคืน
`SKIPPED_STAGE` โดยไม่เคลม/ซื้อ/ย่อยและไม่สร้าง dependency failure ให้ controller อื่น

ดีบักล่าสุดของ `main.lua` อยู่ที่:

```text
AnimeOrigin/MainRoute_<UserId>_latest.log
AnimeOrigin/MainRoute_<UserId>_latest.json
```

หยุดเฉพาะตัวจัดเส้นทางได้ด้วย `AnimeOriginMain.stop()`

Optimizer ใช้ `Config.optimizer.profile = "MultiAccount"` เป็นค่าเริ่มต้น:
หน้าต่างที่กำลังดูทำงานที่ 30 FPS ส่วนไอดีเบื้องหลังลดเหลือ 10 FPS พร้อมปิด 3D
และซ่อน PlayerGui หลังรอ runtime 12 วินาที เมื่อสลับกลับมาหน้าต่างนั้น ภาพและ UI
จะคืนอัตโนมัติ โดยไม่ทำลาย `workspace.Path.Model`, `workspace.Towers`,
`workspace.Enemies`, Remotes หรือ LocalScripts ใช้
`AnimeOriginOptimizer.stop()` เพื่อหยุด watcher และคืน 3D/UI/FPS ทันที

โหมด aggressive จะสร้างไฟล์วัดผลล่าสุดอัตโนมัติทุก 15 วินาที โดยเขียนทับไฟล์
เดิมและเก็บสูงสุด 120 ตัวอย่าง จึงไม่สร้าง log หรือ table ที่โตไม่จำกัด:

```text
AnimeOrigin/RuntimeLeakWatch_<UserId>_latest.json
```

ข้อมูลประกอบด้วย Total memory, Lua heap, DeveloperMemoryTag, FPS/frame time,
จำนวน descendant แยกชนิดใต้ PlayerGui และ snapshot ของ Towers/Enemies/Debris
ทุก 4 ตัวอย่าง หาก RAM หรือ PlayerGui เพิ่มต่อเนื่อง 4 ตัวอย่างจะบันทึก alert เพื่อ
แยกว่าบวมจาก GUI, Lua/Signals, texture/mesh หรือ object ฝั่งแมตช์ หลัง Replay,
Next, Return Lobby หรือ Restart ที่เซิร์ฟเวอร์ยืนยันแล้ว `main.lua` จะเรียก cleanup
ซ้ำที่ 0, 0.5 และ 2 วินาที: clone ใหม่ที่มี marker ตรงจะถูก Destroy เฉพาะใต้
PlayerGui ส่วน End Screen เดิมที่เกม reuse จะถูกซ่อน ไม่แตะหลักฐาน gameplay ใดๆ

วัดผลก่อน–หลังแบบ read-only โดยรัน `Probes/PerformanceProbe.lua` ในล็อบบี้,
เริ่มแมตช์, เวฟเป้าหมาย และแมตช์ที่สอง ผลลัพธ์จะอยู่ที่
`AnimeOrigin/PerformanceProbe_<PlaceId>_<timestamp>.json`

ตรวจสอบพาท `TotalSummons` และสถานะรางวัลโดยไม่เปิด Profile:

```text
Probes/OriginBootstrapStateProbe.lua
```

Probe จะบันทึก `AnimeOrigin_BootstrapStateProbe.json` ลง workspace ของ executor
ไม่ใช่ลงโฟลเดอร์โปรเจกต์นี้ ปัจจุบัน V2 ยืนยันพาทหลักครบแล้ว จึงใช้ Probe
เฉพาะเมื่อต้องตรวจสอบโครงสร้างเกมหลังอัปเดต ไม่ต้องรันก่อน FastMode ทุกครั้ง

ค้นหาข้อมูลสำหรับระบบอัปเลเวล/ย่อยยูนิตโดยไม่เปิด Units หรือ Gold Shop:

```text
Probes/OriginUnitProgressionProbe.lua
```

ผลลัพธ์อยู่ที่ `AnimeOrigin/UnitProgressionProbe_latest.json` ใน workspace ของ
executor และเป็น read-only: ไม่ซื้อ ไม่ล็อก ไม่ป้อน Food และไม่ย่อยยูนิต

ค้นหาหลักฐานสำหรับโฟลว์เลือกด่านของ `main.lua` โดยไม่เปิด UI และไม่ยิงรีโมต:

```text
Probes/MainFlowStateProbe.lua
```

โพรบอ่าน EXP/เลเวล, `StoryProgress.WestCity` Act 1–6, Infinite progress,
ตัวเลือกด่านใน runtime, Wave, สถานะเริ่ม/จบแมตช์ และผลแพ้ชนะ พร้อมเฝ้าการ
เปลี่ยนแปลงระหว่างจบแมตช์หรือ Restart ผลล่าสุดอยู่ที่
`AnimeOrigin/MainFlowProbe_latest.json` และประวัติเหตุการณ์อยู่ที่
`AnimeOrigin/MainFlowProbe_trace.jsonl` ใน workspace ของ executor หยุดด้วย
`AnimeOriginMainFlowProbe.stop()`
