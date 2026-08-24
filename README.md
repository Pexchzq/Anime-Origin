# Anime Origin

โปรเจกต์ถูกแยกตามหน้าที่เพื่อให้ไฟล์ที่ต้องรันจริงไม่ปะปนกับเครื่องมือค้นหาพาท

## ไฟล์หลัก

| ไฟล์ | หน้าที่ |
| --- | --- |
| `Loader.lua` | ตัวโหลดสำหรับ executor ที่รันจาก URL (Volthelper/Voit) รอ `game:IsLoaded()`, arm `queue_on_teleport`, หน่วงแบบสุ่ม แล้วดาวน์โหลด Config + worker ทั้งหมด |
| `Config.lua` | คอนฟิกกลาง ต้องรันก่อนสคริปต์ที่อ่านการตั้งค่า |
| `FastMode.lua` | เคลมรางวัลและเควสทุกไอดี; เฉพาะบัญชีใหม่จึงสุ่มตาม Gems โดยยืนยัน `TotalSummons` และยอด Gems ทุกชุด |
| `UnitProgression.lua` | ล็อกยูนิตที่กำหนด จัดอันดับ Top 6 ย่อยตัวซ้ำ ซื้อ/ป้อน Food และเฉลี่ยเลเวล 1–3 ก่อน 4–6 |
| `InGameSettings.lua` | ซิงก์ Settings, Game Speed และ Summon Auto Sell จากค่าจริงใน PlayerData |
| `AutoPlay.lua` | เลือกทีม วาง และอัปเกรดยูนิตภายในด่าน |
| `main.lua` | เลือกเส้นทาง Fast Gems, เข้า Story Pod ด้วย `firetouchinterest`, เริ่มด่าน และจัดการ Next/Replay/Lobby/Infinite restart โดยยืนยันสัญญาณจากเซิร์ฟเวอร์ |
| `Optimizer.lua` | ลดเอฟเฟกต์/เรนเดอร์/เสียง/FPS, ล้าง transient End Screen/Reward popup หลังเซิร์ฟเวอร์ยืนยัน transition และวัดแนวโน้ม RAM/CPU/PlayerGui แบบ bounded |
| `logstats.lua` | ตัวสังเกตการณ์แบบ read-only พิมพ์บรรทัดเดียว (Status/Level/Gems/TraitReroll/Farm) เมื่อค่าเปลี่ยน ไม่ยิงรีโมตและไม่เปิด UI |

## โฟลเดอร์

- `Probes/` — สคริปต์อ่านค่า ค้นหาพาท และ tracer สำหรับดีบัก ไม่ใช่ไฟล์รันปกติ
- `Registry/` — เอกสารพาทและรีโมตที่ยืนยันแล้ว ไม่มีการยิงรีโมต
- `Docs/` — แผนและหลักฐานการออกแบบ
- `Tests/` — เกตแบบ static และตัวไล่วิเคราะห์ log/JSON จริง (Python) ไม่รันเกม

เอกสารใน `Docs/`:

| ไฟล์ | เนื้อหา |
| --- | --- |
| [`KnownIssues.md`](Docs/KnownIssues.md) | **อ่านก่อนเริ่มแก้อะไร** บั๊กที่ยืนยันแล้วยังไม่แก้, โค้ดตาย, งานที่รอวัดผล และทฤษฎีที่พิสูจน์แล้วว่าผิด |
| [`OptimizationDecisionMap.md`](Docs/OptimizationDecisionMap.md) | โหนดตัดสินใจเรื่องประสิทธิภาพ พร้อมบล็อก Shipped ที่บอกว่าอะไรลงจริงแล้วและหลักฐานคืออะไร |
| [`PlanMode.md`](Docs/PlanMode.md) | ลำดับรันปัจจุบัน + ประวัติการออกแบบ Phase 1 (ส่วนหลังไม่ใช่พฤติกรรมปัจจุบัน) |

## รันหลายไอดีบนเครื่องเดียว

`Loader.lua` ออกแบบสำหรับเครื่องที่เปิด Roblox หลายสิบ client พร้อมกัน ลำดับในไฟล์นี้
สำคัญและห้ามสลับ:

1. รอ `game:IsLoaded()` — Auto-Execute ยิงตั้งแต่ client attach ซึ่งบนเครื่องที่โหลด
   หนักจะเกิดก่อนเกมพร้อมเล่นมาก ทุก controller อ่าน state จริง (remotes, Workspace,
   PlayerData) การเริ่มเร็วเกินไปคือสาเหตุที่ client attach แล้วไม่ทำอะไร
2. arm `queue_on_teleport` — ต้องทำ **ก่อน** หน่วงเวลา ไม่งั้นถ้าเทเลพอร์ตเกิดขึ้น
   ระหว่างหน่วง สคริปต์จะหลุดไปเลย
3. หน่วงแบบสุ่ม — กัน thundering herd ตอนทุก client ดาวน์โหลด 8 ไฟล์และเดิน Lua heap
   พร้อมกัน ปรับได้ด้วย:

```lua
getgenv().AnimeOriginLoaderJitter = 20 -- วินาที ค่าเริ่มต้น 8
```

`Optimizer.lua` มี jitter ของตัวเองแยกต่างหาก (`optimizer.maximumStartupJitter`)
สำหรับหน่วง optimisation pass เท่านั้น

ทุก controller จำกัดขนาด log ทั้งใน memory และบนดิสก์: ring `maximumRetainedLogLines`
บรรทัด และไฟล์ `maximumLogBytes` ไบต์ (ค่าเริ่มต้น 1 MB) เมื่อไฟล์เกินขนาดจะเริ่มใหม่
จาก tail ที่เก็บไว้ จึงไม่มี log ที่โตไม่จำกัดข้ามคืน

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

การค้น `getgc(true)` มี backoff: เริ่มที่ `runtimeDiscoveryInterval` แล้วขยายขึ้นจนถึง
เพดาน แทนการเดิน heap ทั้งก้อนทุกครึ่งวินาทีจนครบ timeout — บนเครื่องที่รันหลายสิบ
client การสแกนถี่คงที่คือ feedback loop ที่ทำให้เครื่องยิ่งช้าแล้วยิ่งสแกนหนักขึ้น

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

FastMode ต้องผูกกับ **PlayerData wrapper** ที่เซิร์ฟเวอร์ยังเขียนถึง ไม่ใช่สำเนา warm-up
ที่หลุดออกมา `getgc` เปิดให้เห็นทั้งสองแบบ และการผูกสำเนาที่ตายแล้วทำให้ทุกการเคลม
รายงานว่า "ไม่มีการเปลี่ยนแปลง" ทั้งที่เซิร์ฟเวอร์เครดิตบัญชีจริง สแกนจึงเลือก wrapper
ก่อนเสมอภายใน `wrapperGraceTimeout` และทุกจุดยืนยันจะ rescan ใหม่แทนการอ่าน
ตารางเดิมซ้ำ

`main.lua` อ่าน `StoryProgress.WestCity` และเลเวลจริงโดยไม่เปิด UI แล้วเลือกตามลำดับ:

1. ด่าน Normal แรกใน Act 1–6 ที่ยังไม่ผ่าน
2. WestCity Act 1 Hard จนถึง `minimumInfiniteLevel`
3. WestCity Infinite Hard และสั่ง `RestartGame` ที่ `restartInfiniteAtWave`

### การเข้า Story Pod

เซิร์ฟเวอร์ไม่รับ `StartSelection` จนกว่าจะเห็นว่าผู้เล่นเข้า Pod แล้ว แต่ `DoorUIPart`
ของ Pod มี `TouchInterest` อยู่ ซึ่งแปลว่า `.Touched` ถูกต่อไว้ฝั่งเซิร์ฟเวอร์ จึงยิง event
นั้นตรงๆ ได้โดยตัวละครไม่ต้องขยับ:

```lua
firetouchinterest(root, doorUIPart, 0)
task.wait(Entrance.touchHoldDelay)
firetouchinterest(root, doorUIPart, 1)
```

วัดจริงด้วย `Probes/PodEntryBypassProbe.lua`: ยิงครั้งเดียวขณะตัวละครยืนห่าง 180 studs
และไม่ขยับเลย เซิร์ฟเวอร์ตอบ `MapSelect` และ `UpdatePlayersInside` ที่ระบุผู้เล่นคนนี้
แล้วรับ `StartSelection` — สำเร็จตั้งแต่ครั้งแรก ไม่มีการเดินและไม่มีการเขียน CFrame

ลำดับปัจจุบันคือ touch ก่อน ถ้าไม่ได้ `MapSelect` ภายใน `touchEntryTimeout` จึงถอยไป
ใช้การเดินเข้า Pod แบบเดิม (สำหรับ executor ที่ไม่มี `firetouchinterest` หรือถ้าเซิร์ฟเวอร์
เลิกเชื่อ replicated touch) ตั้ง `useTouchInterestEntry = false` เพื่อบังคับใช้การเดินเสมอ

หลักฐานยังเหมือนเดิมทุกขั้น: `StartSelection` ต้องได้รับ `AfterMapSelect` ที่ตรงกัน และ
`StartTeleport` ต้องได้รับ `TeleportGui` หรือ `LocalPlayer.OnTeleport` จึงถือว่าสำเร็จ
การยิงรีโมตเฉยๆ ไม่นับเป็นความสำเร็จ

> ทฤษฎีที่ **พิสูจน์แล้วว่าผิด**: `preferDirectSelection` เคยตั้งบนสมมติฐานว่ายิง
> `StartSelection` ได้เลยโดยไม่ต้องเข้า Pod ผลจริงคือเซิร์ฟเวอร์ปฏิเสธ 26 จาก 26 ครั้ง
> ค่าเริ่มต้นจึงเป็น `false` และเก็บไว้เป็นบันทึกว่าเคยลองแล้ว

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

เส้นทางของ `main.lua` มี supervisor แบบมีขอบเขต: error ระหว่างเดินเส้นทางจะรีสตาร์ทได้
สูงสุด `maximumRouteRestarts` ครั้ง โดยตัดการเชื่อมต่อและผูก listener ใหม่ทุกครั้ง
ก่อนหน้านี้ error เดียวจบ session ทั้งหมด เพราะ Loader เรียก `main.lua` แค่ครั้งเดียว
ด้วย `task.spawn` + `pcall`

ดีบักล่าสุดของ `main.lua` อยู่ที่:

```text
AnimeOrigin/MainRoute_<UserId>_latest.log
AnimeOrigin/MainRoute_<UserId>_latest.json
```

หยุดเฉพาะตัวจัดเส้นทางได้ด้วย `AnimeOriginMain.stop()`

## Optimizer

Optimizer ใช้ `Config.optimizer.profile = "MultiAccount"` เป็นค่าเริ่มต้น ค่าที่ใช้จริง
ตอนนี้:

| ค่า | ปัจจุบัน | เหตุผล |
| --- | --- | --- |
| `lockFps` | `true` | เคยเป็น `false` ทำให้ cap ทุกตัวด้านล่างไม่มีผลเลย client เบื้องหลังหลายสิบตัวจึงเรนเดอร์เต็มที่ |
| `fpsCap` / `foregroundFpsCap` / `backgroundFpsCap` | `30` ทั้งหมด | `task.wait` คืนค่าบน Heartbeat ดังนั้น frame time คือพื้นของทุก poll loop โพลที่ถี่ที่สุดคือ `statePollInterval = 0.1` ซึ่ง cap 10 FPS (100ms/เฟรม) จะทับพอดีและทำให้หน้าต่างยืนยันรีโมตอดตาย 30 FPS ให้เฟรม 33ms ต่ำกว่าพื้นนั้นชัดเจน |
| `disable3DWhenUnfocused` | `false` | กันจอขาว/จอว่างตอนหน้าต่างไม่ได้โฟกัส |
| `hidePlayerGuiWhenUnfocused` | `false` | เกมเปลี่ยน HUD จาก disabled เป็น enabled ได้ตอนอยู่เบื้องหลัง การคืนค่า boolean เก่าจะซ่อน HUD ด่าน/เวฟแม้กลับมาโฟกัสแล้ว |
| `disable3DRendering` | `false` | headless ตลอดเวลาเป็นของโปรไฟล์ `Headless` เท่านั้น |

การลด `backgroundFpsCap` ต่ำกว่า 30 คือการประหยัดก้อนถัดไปที่ชัดที่สุด แต่ต้องวัดกับ
จังหวะการวางยูนิตในแมตช์จริงก่อน ไม่ใช่เดา — เกต `Tests/check_optimizer_safety.py`
บังคับพื้นไว้ที่ 20 FPS (ครึ่งหนึ่งของ poll interval ที่ถี่ที่สุด)

Optimizer ไม่ทำลาย `workspace.Path.Model`, `workspace.Towers`, `workspace.Enemies`,
Remotes หรือ LocalScripts; Workspace root ที่ยอมให้ลบได้มีเฉพาะที่ระบุใน
`mapRootsToDestroy` (`Map`, `MapTrash`) ใช้ `AnimeOriginOptimizer.stop()` เพื่อหยุด
watcher และคืน 3D/UI/FPS ทันที

โปรไฟล์ที่รองรับคือ `Safe`, `Farm`, `MultiAccount` และ `Headless` (`Farm` ครอบคลุม
`MultiAccount` และ `Headless` ด้วย) แต่พฤติกรรมจริงมาจากธงในตารางด้านบน ไม่ใช่จาก
ชื่อโปรไฟล์

`leakTelemetry = true` (เปิดอยู่ ไม่ผูกกับโปรไฟล์ใด) จะเขียนไฟล์วัดผลล่าสุดทุก 15 วินาที
โดยเขียนทับไฟล์เดิมและเก็บสูงสุด 120 ตัวอย่าง จึงไม่สร้าง log หรือ table ที่โตไม่จำกัด:

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

## โพรบอื่น

ตรวจว่าการเข้า Pod บายพาสได้หรือไม่ และเซิร์ฟเวอร์ใช้กลไกตรวจจับแบบใด:

```text
Probes/PodEntryBypassProbe.lua
```

ค่าเริ่มต้นเป็น read-only: รายงานว่า Pod ใช้ `TouchTransmitter`, `ClickDetector` หรือ
`ProximityPrompt` แล้วลอง `firetouchinterest` ทั้งแบบ root/leg และสลับลำดับอาร์กิวเมนต์
โดยรอ `MapSelect` ของเซิร์ฟเวอร์เองหลังแต่ละครั้ง จะยิง `StartTeleport` ก็ต่อเมื่อตั้ง
`getgenv().AnimeOriginPodProbeTeleport = true` เท่านั้น

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

## การวินิจฉัยจาก F9

`Config.console.statusOnly = true` ทำให้รอบปกติเงียบ ซึ่งดีสำหรับการฟาร์ม แต่แปลว่า
client ที่ executor ไม่ inject, client ที่โหลดไฟล์พัง และ client ที่ทำงานปกติ
**ให้คอนโซลว่างเปล่าเหมือนกันหมด** จึงมี trace channel แยกที่ไม่สนใจ `statusOnly`:

```lua
Config.console.diagnostics = true -- ค่าเริ่มต้น
```

รูปแบบบรรทัด — เลข sequence สำคัญพอๆ กับข้อความ เพราะ Roblox สลับเอาต์พุตจากหลาย
thread การจับภาพคอนโซลจึงเรียงลำดับกลับไม่ได้ถ้าไม่มีมัน:

```text
[AO][007][  12.4s][LOADER] download 4/8 main.lua ok {"kb":"73.8","seconds":"0.31","attempts":1}
[AO][019][  31.2s][Main] bootstrap gate waiting {"FastMode":"RUNNING","UnitProgression":"RUNNING"}
```

พิมพ์เฉพาะ **milestone** ไม่ใช่ทุก action เพราะคอนโซลของ Roblox เป็น ring ที่มีขอบเขต
ถ้าพิมพ์ถี่ บรรทัดของ Loader จะถูกดันหายก่อนมีคนได้อ่าน รอบที่สมบูรณ์ดีอยู่ที่ ~35 บรรทัด

| tag | บอกอะไร |
| --- | --- |
| `LOADER` | attach, capability ของ executor, teleport queue, การรอเกมโหลด, jitter, ทุกไฟล์ที่ดาวน์โหลด (KB/วินาที/จำนวนครั้งที่ retry), `ready:` หรือ `ABORT` |
| `FastMode` / `UnitProgress` | start, การผูก PlayerData, การรอ dependency, สถานะ terminal |
| `Main` | context LOBBY/STAGE, ทุกการเปลี่ยนของ bootstrap gate, ด่านที่เลือก, การเข้า Pod, `StartSelection`, การลงจอดของเทเลพอร์ต, restart/FATAL |
| `Settings` / `AutoPlay` / `Optimizer` / `LogStats` | start และสถานะ terminal |

ปิดได้ด้วย `Config.console.diagnostics = false` และปิดเฉพาะฝั่ง Loader ด้วย
`getgenv().AnimeOriginLoaderTrace = false`

Loader retry การดาวน์โหลดที่พลาดแบบมี backoff (`AnimeOriginLoaderDownloadRetries`
ค่าเริ่มต้น 3) เพราะ `game:HttpGet` **raise** เมื่อพลาด และเดิมเรียกแบบไม่มี pcall
ที่ module scope — response เดียวที่โดน throttle เคยฆ่า client ทั้งตัวไปทั้ง session

## Tests

`Tests/` เป็น Python ล้วน ไม่รันเกม แบ่งเป็นสองชนิด:

**เกตแบบ static** (`check_*.py`) — อ่านซอร์สแล้วยืนยันว่า invariant ยังอยู่ เช่น
`check_optimizer_safety.py` บังคับพื้น FPS และรายการ Workspace root ที่ลบได้
ส่วน `check_story_portal_failover.py` บังคับว่าความสำเร็จต้องมาจากหลักฐานฝั่งเซิร์ฟเวอร์
(`AfterMapSelect` ที่ตรงกัน, `teleportGeneration` เพิ่มขึ้น) ไม่ใช่จากรูปร่างของ control flow

`check_lag_resilience.py` เป็นเกตสำหรับอาการที่เกิดเฉพาะตอนเครื่องโหลดหนัก: บังคับว่า
ทุกการรอต้องมีขอบเขต (ห้ามมี `signal:Wait()` เปล่าในไฟล์ที่รันจริง), `enterStoryPortal`
ต้องรอ Pod replicate แทนการยอมแพ้ทันที, bootstrap gate ต้องแยก "worker ตายเงียบ" ออกจาก
"worker ยังทำงานอยู่" และ `Loader.lua` ต้อง arm `queue_on_teleport` ก่อนจะ yield ครั้งแรก

**ตัวไล่วิเคราะห์** (`diagnose_*.py`) — อ่าน log/JSON จริงจากรอบที่รันไปแล้ว ไม่ grep
ซอร์ส Lua ตรวจอาการอย่าง `STALE_PLAYERDATA` (เคลมโค้ดใหม่หลายตัวแต่ไม่มีหลักฐาน
การเปลี่ยนแปลงเลย), `BOOTSTRAP_SEALED_EMPTY` (ปิด bootstrap ทั้งที่ยืนยันได้ 0 ชุด),
`STAGE_ENTRY_BLOCKED` (portal ล้มเหลวโดยไม่มี `MAP_EVENT` เลยสักครั้ง)

ตรวจ syntax ทุกไฟล์ Lua:

```bash
Tests/check_syntax.sh
```
