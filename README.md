# Anime Origin

โปรเจกต์ถูกแยกตามหน้าที่เพื่อให้ไฟล์ที่ต้องรันจริงไม่ปะปนกับเครื่องมือค้นหาพาท

## ไฟล์หลัก

| ไฟล์ | หน้าที่ |
| --- | --- |
| `Loader.lua` | ตัวโหลดสำหรับ executor ที่รันจาก URL (Volthelper/Voit) รอ `game:IsLoaded()`, arm `queue_on_teleport`, หน่วงแบบสุ่ม แล้วดาวน์โหลด Config + worker ทั้งหมด |
| `Config.lua` | คอนฟิกกลาง ต้องรันก่อนสคริปต์ที่อ่านการตั้งค่า |
| `FastMode.lua` | เคลมรางวัลและเควสทุกไอดี; เฉพาะบัญชีใหม่จึงสุ่มตาม Gems โดยยืนยัน `TotalSummons` และยอด Gems ทุกชุด ในด่านจะข้าม bootstrap แต่ยังวนเคลมเควสต่อ |
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

## การเคลมเควส

`Claimable` ใน `PlayerData.Quests` **ถูกเขียนโดย UI ของเควสตอน render ไม่ใช่ค่าที่เซิร์ฟเวอร์
replicate** โปรเจกต์นี้อ่าน PlayerData โดยไม่เปิด UI จึงเห็น `false` เสมอ (396 จาก 396
record ใน capture) การเอาไปเป็นเงื่อนไขก่อนยิงจึงบล็อกการเคลมทั้งหมด — `ClaimAllQuests`
ไม่เคยถูกยิงเลยสักครั้งบนไอดีไหนก็ตาม

ตอนนี้ยิงโดยไม่มีเกต แล้วพิสูจน์จาก `Claimed` ซึ่งเซิร์ฟเวอร์เป็นคนเขียน การเคลมรางวัลฟรี
ไม่มีงบให้เสีย เซิร์ฟเวอร์ no-op เองเมื่อไม่มีอะไรให้เคลม ต่างจากการสุ่มที่เสียเพชร

เควสสร้างความคืบหน้า**ระหว่างแมตช์** และ Infinite ใช้ `RestartGame` โดยไม่กลับล็อบบี้
FastMode จึงยังเป็น worker ของล็อบบี้เหมือนเดิม แต่ในด่านจะ publish `SKIPPED` ทันที
(main's bootstrap gate อ่านค่านี้ ห้ามหน่วง) แล้วเปิดลูปเคลมเควสค้างไว้:

```lua
Config.fastGems.stageQuestClaim = {
	enabled = true,
	startupDelay = 30,  -- ให้แมตช์เริ่มก่อน
	interval = 180,
	jitter = 45,        -- กัน 54 client ยิงรีโมตพร้อมกันทุก interval
	maximumAttempts = 0, -- 0 = ตลอดอายุของด่านนั้น
}
```

ลูปนี้แยกไฟล์ล็อกเป็น `FastModeStageQuests_<UserId>_latest.log` และ **ไม่แตะ
bootstrap state** เลย เพราะไฟล์นั้นเก็บความคืบหน้าการสุ่มของล็อบบี้ และไฟล์ล็อกจะถูก
truncate ตอนโหลด ล็อกเฉพาะตอนเคลมได้จริงเท่านั้น ไม่ล็อก no-op

ล็อกไว้ด้วย `Tests/check_quest_claim_gate.py`

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

## โฟลเดอร์ดีบัก (AnimeOriginDiag)

trace ใน F9 ตอบได้ว่า "โค้ดเดินไปถึงไหน" แต่ตอบไม่ได้ว่า **"ที่เดินไปนั้นได้ผลจริงมั้ย"**
และบั๊กทุกตัวที่โปรเจกต์นี้เคยเจอเป็นแบบหลังทั้งหมด — ฟังก์ชันรันจบ ไม่ error
เขียนล็อกว่าสำเร็จ แต่ไม่ได้ทำอะไรเลย:

- `claimAllQuests` return ตั้งแต่ต้นเพราะธง UI → ไม่เคยยิงรีโมตสักครั้ง
- `returnToLobby` ยิงรีโมต เซิร์ฟเวอร์รับ แต่ตัวละครไม่เคยออกจากด่าน
- `claimConfiguredRewards` ฆ่างาน 5 ตัวที่กำลังทำสำเร็จอยู่

**ไม่มีล็อกไหนจับได้ เพราะโค้ดทำตามที่สั่งทุกอย่าง** `Diag.lua` จึงไม่บันทึกว่าโค้ดทำอะไร
แต่บันทึกว่า **หลักฐานที่ประกาศไว้ล่วงหน้าปรากฏหรือไม่**

### สี่คำตัดสิน

| verdict | ความหมาย |
| --- | --- |
| `OK` | รันแล้ว และหลักฐานที่ประกาศไว้ปรากฏจริง |
| `NO_OP` | รันจบ ไม่ error แต่**หลักฐานไม่เคยปรากฏ** ← คลาสที่กัดซ้ำๆ |
| `FAIL` | รันแล้วรายงานความล้มเหลวของตัวเอง |
| `STUCK` | เริ่มแล้วไม่เคยจบ ← คำตอบตรงๆ ของ "ไอดีนี้ค้างอยู่ที่ฟังก์ชันไหน" |

`NO_OP` กับ `STUCK` คือสองอย่างที่ล็อกเดิมทั้งหมดของโปรเจกต์นี้ผลิตไม่ได้

### ลูกโซ่

ไอดีตายทีนึงมักไม่ได้พังจุดเดียว — FastMode ตาย → gate ของ main รอ worker
ที่ไม่มีวันรายงาน → route restart 3 รอบ → AutoPlay ไม่เคยได้ด่าน
มีเส้นเชื่อมสองชนิดที่ทำให้ **ประกอบกลับได้จริง ไม่ใช่เดา**:

- `parent` — step ที่เปิดซ้อนใน step อื่น (แยกตาม coroutine worker 7 ตัวจึงไม่ปนกัน)
- `signal` — step ที่ผลลัพธ์ขึ้นกับค่าที่ controller อื่นเขียน **บันทึกตอนอ่าน**
  (`step:because("lifecycle.FastMode")`)

digest บอก **หัวลูกโซ่** (ลิงก์แรกที่ไม่ใช่ OK) ให้เอง ที่เหลือคือผลพวง —
การไปแก้ผลพวงคือสาเหตุที่บั๊กกลับมา

### ไฟล์

โฟลเดอร์ **`AnimeOriginDiag/` แยกจาก `AnimeOrigin/` โดยตั้งใจ** ทุกอย่างในนั้นเกิดจาก
รอบรันเดียว **ลบทิ้งเมื่อไหร่ก็ได้** ต่างจาก `AnimeOrigin/` ที่เก็บ
`FastModeBootstrap_*.json` และ `MainRoute_*.json` ซึ่งเป็น state ที่ไอดีค้างกลางคันต้องใช้

| ไฟล์ | คืออะไร |
| --- | --- |
| `digest_<uid>.json` | คำตัดสิน เล็ก (~4–8 KB) **ไฟล์นี้คือไฟล์ที่ส่งมาให้วิเคราะห์** |
| `events_<uid>.jsonl` | สตรีมเหตุการณ์ดิบ จำกัด 64 KB ต่อไอดี |
| `README.txt` | บอกว่าโฟลเดอร์นี้ลบได้ เขียนไว้ให้คนที่มาเจอทีหลัง |

54 ไอดี × 64 KB = ~3.5 MB zip แล้วเหลือหลักร้อย KB — **ส่งได้จริง** ต่างจาก raw log
ที่ไอดีเดียวเคยกิน 568 KB ใน 12 ไฟล์

digest ถูกเขียนทับทุก 10 วินาที ไม่ใช่ตอนจบ เพราะ **ไอดีที่ค้างไม่มีวันเดินไปถึงตอนจบ**
และไอดีนั้นคือไอดีที่น่าอ่านที่สุด

⚠️ ไฟล์พวกนี้มี Roblox UserId และ repo นี้เป็น **public** — `.gitignore` กันไว้แล้ว
ห้ามคอมมิตเข้ามาเด็ดขาด

### อ่านผล

```bash
Tests/diagnose_diag_capture.py                    # โฟลเดอร์จริงบนเครื่อง
Tests/diagnose_diag_capture.py ~/Downloads/x.zip  # capture ที่ส่งมา
Tests/diagnose_diag_capture.py --account 1000000001
```

ตัวจัดกลุ่มสำคัญกว่ารายไอดี — capture รอบที่แล้วใช้เวลาทั้งคืนไล่อ่านล็อก 12 ไฟล์ต่อไอดี
กว่าจะได้ข้อสรุปว่า "6 ตายแบบนึง 6 ตายอีกแบบ 28 ปกติ" ตอนนี้เป็น output บรรทัดเดียว

### ปิด / ปรับ

```lua
Config.debugRecorder.enabled = false   -- ปิดทั้งหมด กลายเป็น no-op ทุกจุดเรียก
Config.debugRecorder.eventByteCap      -- 65536
Config.debugRecorder.digestInterval    -- 10
Config.debugRecorder.defaultStepDeadline -- 90
```

**สัญญาความปลอดภัย** — นี่คือผู้สังเกตการณ์แบบ passive บนไคลเอนต์ ~54 ตัวที่ไม่มีคนเฝ้า
มันต้อง **ทำให้รอบรันพังไม่ได้เลย**: ทุกจุดเรียกสาธารณะห่อ pcall,
ไคลเอนต์ที่โหลด `Diag.lua` ไม่สำเร็จรันเหมือนเดิมทุกอย่าง (Loader ตั้งใจให้ดาวน์โหลดไฟล์นี้
**ไม่ fatal** ต่างจากอีก 8 ไฟล์), และทุก container มีเพดาน

## สกิล: verify-from-evidence

`.claude/skills/verify-from-evidence/` — บทเรียนทั้งหมดจากโปรเจกต์นี้ เขียนให้คนอื่น
และเอเจนต์อื่นอ่านแล้วทำงานต่อได้ทันที ไม่ต้องไล่อ่านซอร์ส 10,000 บรรทัดก่อน

แก่นคือประโยคเดียว: **บั๊กทุกตัวที่โปรเจกต์นี้เคยปล่อยออกไป คือฟังก์ชันที่รันจบ
ไม่ error เขียนล็อกว่าสำเร็จ แล้วไม่ได้ทำอะไรเลย** — ล็อกที่บันทึก "โค้ดทำอะไร"
จับไม่ได้สักตัว เพราะโค้ดทำตามที่สั่งครบทุกอย่าง

| ไฟล์ | มีอะไร |
| --- | --- |
| `SKILL.md` | กฎ 10 ข้อ + เช็คลิสต์ก่อนเขียน/ก่อนปิดงาน/ก่อนรายงาน |
| `references/case-files.md` | บั๊กจริง 8 ตัว: อาการ → ล็อกบอกว่าอะไร → ความจริงคืออะไร → **ทำไมถึงมองไม่เห็น** → กฎที่ได้มา |
| `references/harness.md` | วิธีสร้าง harness รันโค้ดที่รันในที่จริงไม่ได้ (stub + นาฬิกาเสมือน) และวิธี mutation-test เกต |

ข้อที่ใช้บ่อยที่สุดสามข้อ:

- **ยิงรีโมตไม่ใช่ผลลัพธ์ มันคือคำขอ** ประกาศหลักฐานที่จะพิสูจน์ก่อน แล้วค่อยไปดูว่ามันมาจริงมั้ย
- **สี่คำตัดสิน ไม่ใช่สอง** — `OK` / `NO_OP` / `FAIL` / `STUCK` สองตัวหลังคือตัวที่ล็อกธรรมดาผลิตไม่ได้
- **เกตที่ล้มเหลวไม่ได้คือของประดับ** — mutation-test มันเสมอ เซสชั่นนี้ทำสองรอบ เจอ mutant รอดทั้งสองรอบ

## Tests

`Tests/` เป็น Python ล้วน ไม่รันเกม แบ่งเป็นสองชนิด:

**เกตแบบ static** (`check_*.py`) — อ่านซอร์สแล้วยืนยันว่า invariant ยังอยู่ เช่น
`check_optimizer_safety.py` บังคับพื้น FPS และรายการ Workspace root ที่ลบได้
ส่วน `check_story_portal_failover.py` บังคับว่าความสำเร็จต้องมาจากหลักฐานฝั่งเซิร์ฟเวอร์
(`AfterMapSelect` ที่ตรงกัน, `teleportGeneration` เพิ่มขึ้น) ไม่ใช่จากรูปร่างของ control flow

`check_diag_contract.py` บังคับสัญญาของ Diag: โฟลเดอร์ต้องไม่ใช่ stateFolder,
ทุกจุดเรียกสาธารณะต้อง pcall, ทุก container ต้องมีเพดาน, ดาวน์โหลด Diag ใน Loader
ต้องไม่ fatal, และทุก step ต้องประกาศหลักฐานที่คาดหวัง

`check_diag_runtime.py` ไม่ใช่เกต static — มัน **รัน `Diag.lua` จริง** ผ่าน `luau`
โดย stub global ของ Roblox และใช้นาฬิกาเสมือน (การตรวจ `STUCK` ขึ้นกับเวลาที่ผ่านไปจริง
เทสต์ที่ต้องรอ 90 วินาทีจริงคือเทสต์ที่ไม่มีใครรัน) มันเล่นซ้ำรูปแบบความพังจากคืนที่ capture ไว้
แล้ว assert digest — ตอนเขียนครั้งแรกมันจับบั๊กจริงใน `Diag.lua` ได้ 3 ตัวที่รีวิวด้วยตาไม่เห็น

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
