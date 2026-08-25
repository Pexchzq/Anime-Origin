# Known Issues

สถานะ ณ commit `0bbb8bc` + ชุดแก้ "ค้างหน้าล็อบบี้" ทุกข้อในนี้ตรวจกับซอร์สจริงแล้ว ไม่ใช่การคาดเดา
ถ้าแก้ข้อไหนแล้วให้ลบออกจากไฟล์นี้ อย่าปล่อยให้เหลือค้าง

---

## ความทนต่อโหลด (แก้แล้ว — ต้องยืนยันในรอบรันจริง)

สี่จุดนี้คือสาเหตุของอาการ "สคริปไม่โหลด" และ "ยืนนิ่งหน้าล็อบบี้" ตอนเครื่องโหลดหนัก
ทั้งหมดเป็นบั๊กชนิดเดียวกัน: **การรอที่ไม่มีขอบเขต หรือการรีบยอมแพ้เมื่อของยังมาไม่ถึง**
ล็อกไว้แล้วด้วย `Tests/check_lag_resilience.py`

| จุด | เดิม | ตอนนี้ |
| --- | --- | --- |
| `main.lua` `enterStoryPortal` | Pod ยังไม่ replicate → `return` ทันที | รอภายใน `occupiedPortalWaitTimeout` (20s) |
| `main.lua` `tryEnterStoryPortal` | `CharacterAdded:Wait()` ไม่มี timeout | `characterWaitTimeout` (10s) |
| `main.lua` `waitForBootstrapWorkers` | worker ตายเงียบ = PENDING ตลอด → รอ 300s | `startupGrace` → นับเป็น FAILED |
| `Loader.lua` | รอเกมโหลดก่อน arm `queue_on_teleport` | arm ก่อน แล้วรอแบบมีขอบเขต 120s |
| `main.lua` `OnTeleport` | นับ `TeleportState.Failed` เป็นหลักฐานว่าเทเลพอร์ตสำเร็จ | แยก `teleportFailureGeneration` ออก + settle watchdog `stageTeleportSettleTimeout` (20s) |
| FastMode / UnitProgression / AutoPlay | `WaitForChild(name)` ไม่มี timeout 24 จุด | `requireChild()` ผูกกับ `remoteWaitTimeout` (30s) แล้วรายงาน FAILED |
| `main.lua` gate timeout | เรียก `fail()` เสมอ ไม่ดู `fatalTasks` | timeout ที่เหลือแต่ worker non-fatal → route ต่อได้ |
| `main.lua` gate budget | ทุก route restart ได้ 300s ใหม่ → 4×300s | `gateStartedAt` ผูกครั้งเดียวต่อล็อบบี้ |
| `Loader.lua` worker error | error ดิบ = lifecycle ค้าง `RUNNING` ตลอดไป | Loader publish `FAILED` ให้ worker ที่ raise ก่อน publish terminal |
| `startupGrace` | `45s` — ต่ำกว่า worst case จริงของ worker (30+30) | `75s` |

**ตัวที่หนักที่สุดคือข้อแรก** — Pod อยู่ใต้ `MainFolder.Lobby.MapSelectors.Story` ซึ่งบนเครื่อง
ที่โหลดหนักจะยัง replicate ไม่เสร็จในไม่กี่วินาทีแรกหลัง join โค้ดเดิม `return` ทันที ทำให้
เผา transition attempt ครบ 6 ครั้ง **และ** route restart ครบ 3 ครั้ง **ก่อนที่ Pod จะมีตัวตน**
สุดท้าย route ตาย ตัวละครยืนนิ่งอยู่บนแมพที่โหลดเสร็จไปแล้วไม่กี่วินาทีหลังจากนั้น

---

## Quests: `Claimable` เป็นธงฝั่ง UI ไม่ใช่ค่าจากเซิร์ฟเวอร์ (แก้แล้ว)

`ClaimAllQuests` **ไม่เคยถูกยิงเลยสักครั้ง** บนไอดีไหนก็ตาม ในรอบรันไหนก็ตาม
state file ทั้ง 8 ไฟล์บันทึกตรงกันหมด: `attempted: false`, `claimable: 0`

โครงสร้างจริงของ `PlayerData.Quests` คือ `{ Daily, Weekly, Permanent, QuestLines }`
แต่ละ record เป็น:

```json
{"HeaderType":"Daily","Claimed":false,"StartAmount":0,"Claimable":false,"QuestIndex":12}
```

`StartAmount` คือ baseline ตอนรับเควส ความคืบหน้าจริงต้องคำนวณจาก
`stat ปัจจุบัน − StartAmount` เทียบ goal ที่ lookup ด้วย `QuestIndex` —
**`Claimable` ถูกเขียนโดย UI ของเควสตอน render ไม่ใช่ค่าที่เซิร์ฟเวอร์ replicate**
โปรเจกต์นี้อ่าน PlayerData โดยไม่เปิด UI จึงเห็น `false` ตลอด: 396 จาก 396 record
ใน discovery trace ขณะที่ `Claimed` ขยับเองได้จริง (ไอดีหนึ่งมี `claimed: 9`)

เกต `if before.claimable <= 0 then return` จึงบล็อก 100% และการ verify
`claimable < before.claimable` = `0 < 0` ก็เป็นเท็จตลอดด้วยเหตุผลเดียวกัน

**ตอนนี้**: ยิงโดยไม่มีเกต (การเคลมรางวัลฟรีไม่มีงบให้เสีย เซิร์ฟเวอร์ no-op เองถ้าไม่มีอะไร
ให้เคลม ต่างจากการสุ่มที่เสียเพชร) แล้วพิสูจน์จาก `Claimed` ซึ่งเซิร์ฟเวอร์เป็นคนเขียน
ล็อกด้วย `Tests/check_quest_claim_gate.py`

**หมายเหตุ**: `gemChange` ยังบันทึกอยู่แต่ห้ามใช้เป็นหลักฐาน — reward job ทั้ง 5 ตัว
รันขนานกัน เพชรที่เพิ่มอาจมาจาก Daily/Playtime/Battlepass/Wheel

ตัว claim อื่นไม่ได้เป็นบั๊กแบบนี้: `codes` และ `playTimeRewards` มี status รายตัวจริง
ส่วน `battlepass`/`dailyReward`/`dailyWheel` มี `attempted: true` ทุกไฟล์

---

## บั๊กที่ยืนยันแล้วและยังไม่แก้

### worker ที่ค้างใน infinite loop ยังตรวจไม่ได้ (แคบลงมากแล้ว)

`RUNNING` ที่ไม่มีวันเปลี่ยนเคยเกิดได้ 3 ทาง ตอนนี้ปิดไป 2:

| ทาง | สถานะ |
| --- | --- |
| infinite yield จาก `WaitForChild` ไม่มี timeout | **ปิดแล้ว** — bounded ทั้ง 24 จุด + เกตบังคับ |
| error ดิบก่อน publish terminal | **ปิดแล้ว** — `Loader.lua` publish `FAILED` แทน |
| infinite loop จริงๆ ในโค้ด worker | ยังตรวจไม่ได้ |

ทางที่สามยังเหลือ แต่ตอนนี้ไม่มี `while true` ในไฟล์ที่รันจริงเลยสักไฟล์ (ยืนยันด้วย grep)
จึงไม่ใช่ทางที่เกิดจริงในซอร์สปัจจุบัน

**ถ้าจะปิดให้ครบ**: ให้ `log()` ของแต่ละ worker ประทับ heartbeat ลง lifecycle entry แล้วให้
main ถือว่า `RUNNING` ที่ heartbeat ค้างเกิน N วินาที = ตาย ข้อควรระวังคือ worker มีช่วงเงียบ
ที่ถูกต้องตามกฎอยู่จริง (`waitForFastModeDependency` เงียบได้ถึง 300s, การรอ PlayerData 60s)
จุดพวกนั้นต้องแตะ heartbeat เองไม่งั้นจะกลายเป็น false positive ที่ฆ่า worker ที่ยังดีอยู่

### `Optimizer.lua:569` — `and false or` ทำให้ `cleanupHiddenGui` ไม่ทำงานเลย

```lua
setProperty(gui, "Enabled", cleanupHiddenGui[gui] and false or guiOriginalStates[gui])
```

ใน Lua `x and false or y` จะได้ `y` **เสมอ** เพราะเมื่อ `x` เป็นจริง `x and false`
ให้ `false` แล้ว `false or y` ก็ให้ `y` ต่อ ดังนั้นเงื่อนไข "ถ้า GUI นี้ถูกซ่อนโดย
cleanup ให้คงซ่อนไว้" ไม่เคยมีผล — ค่าที่คืนคือ `guiOriginalStates[gui]` ทุกกรณี

`cleanupHiddenGui` ถูกเขียนที่บรรทัด 662 และอ่านที่ 569 เท่านั้น กลไกทั้งก้อนจึงตาย
ผลกระทบจำกัด เพราะ `hidePlayerGuiWhenUnfocused = false` อยู่แล้ว เส้นทางนี้จึงแทบ
ไม่ถูกเรียก แต่ถ้าเปิดธงนั้นเมื่อไหร่บั๊กจะโผล่ทันที

### `UnitProgression` หา level formula ไม่เจอบนบางไอดี

`UnitProgression.lua:518` — `LEVEL: Level formula module was not found.`

ล้มเหลว 5 จาก 18 ไอดีในชุด log ล่าสุด (ลดจาก 7 หลังแก้ predicate ให้ `snapshotIsUsable`
ตรวจครบทั้ง 3 ฟิลด์เท่ากับที่ scan จริงต้องการ) 3 ไอดีถูกกู้คืนได้ด้วยการ rescan
สาเหตุที่เหลือยังไม่ทราบ รอยืนยันการแก้ประตูก่อนแล้วค่อยไล่ต่อ

---

## โค้ดตาย

ทั้งสองตัวถูกประกาศแต่ไม่มีที่ใดเรียก (`grep -c` ได้ 1 = มีแค่บรรทัดนิยามเอง):

- `AutoPlay.lua:1355` — `findTowerForUnit`
- `Optimizer.lua:683` — `cleanupPass`

---

## เทสต์ที่ล้มบนเครื่องนี้ (ปัญหาสภาพแวดล้อม ไม่ใช่โค้ด)

`Tests/check_lobby_runtime_gate.py` ฮาร์ดโค้ดพาทกระจกของ MacSploit ที่อยู่นอก repo:

```
/Users/siwakantalasak/Documents/Macsploit Workspace/AnimeOrigin
/Users/siwakantalasak/Documents/Macsploit Automatic Execution/1Config.lua
/Users/siwakantalasak/Documents/MacsploitUI/scripts/1Config.lua
```

ยืนยันแล้วด้วย `git stash` ว่าล้มมาก่อนการแก้ล่าสุด ไม่ใช่ regression ถ้าจะให้รันได้
ทุกเครื่องต้องเปลี่ยนให้ข้ามอย่างมีเหตุผลเมื่อไม่มีพาท แทนที่จะ fail

---

## งานที่เสนอแล้วแต่ยังไม่ทำ (รอวัดผล `bde3928` ก่อน)

### Loader disk cache

54 clients × 8 ไฟล์ต่อการ teleport ≈ **8,600 requests/ชั่วโมง** ไปที่ GitHub
(392.6 KB ต่อ client ต่อการ join = 20.7 MB ต่อหนึ่งระลอก)
ควรแคชลงดิสก์แล้วดาวน์โหลดใหม่เฉพาะเมื่อไฟล์เปลี่ยน

**ลงไปแล้วบางส่วน**: retry + backoff + ปฏิเสธ body ว่าง (`game:HttpGet` raise เมื่อพลาด
และเดิมเรียกที่ module scope โดยไม่มี pcall — response เดียวที่โดน throttle ฆ่า client
ทั้งตัวเงียบๆ ไปทั้ง session) แต่ retry ลดความเสียหาย ไม่ได้ลดจำนวน request

**ยังไม่ทำ** disk cache ตัวจริง เพราะต้องรู้ก่อนว่าการดาวน์โหลดพลาดจริงหรือไม่ —
trace `[AO][LOADER] download i/8 ... attempts=N` ตอบข้อนี้ได้จาก F9 รอบเดียว
ถ้า `attempts` เป็น 1 ตลอด แปลว่า cache เป็นแค่การประหยัด ไม่ใช่การแก้บั๊ก

### แชร์ getgc snapshot ระหว่าง controller

ตอนนี้ 5 controller เดิน Lua heap คนละรอบ (snapshot วัดได้ 41k–404k objects,
median ~95k) ถ้าแชร์กันจะเหลือรอบเดียว

**ข้อควรระวัง**: นี่เสี่ยงพาบั๊ก stale PlayerData กลับมา TTL ต้องสั้นมาก และ
`rescanPlayerData` ต้องบังคับเดิน heap ใหม่เสมอ ห้ามอ่านจากแคช

### Headless auto-fallback

`Docs/OptimizationDecisionMap.md` โหนด `headless-profile` ระบุว่าต้องถอยกลับไป Farm
อัตโนมัติเมื่อการยืนยัน MatchRuntime/WaveVote/placement/upgrade ช้าเกินงบ —
**ยังไม่ได้เขียน** `disable3DRendering` จึงยังเป็น `false` และ `Headless` ยังเป็น opt-in

### วัด `backgroundFpsCap` ต่ำกว่า 30

เป็นการประหยัด CPU ก้อนถัดไปที่ชัดที่สุด แต่ต้องวัดกับจังหวะวางยูนิตในแมตช์จริง
`Tests/check_optimizer_safety.py` บังคับพื้นไว้ที่ 20 FPS

### ขนส่ง log จาก 54 ไอดี

ไอดีที่รันยาวไอดีเดียวผลิต 568.6 KB จาก 12 ไฟล์ในชุดเดียว แม้จะมี cap 1 MB ต่อไฟล์
แล้ว raw log จาก 54 ไอดีก็ยังส่งไม่ไหว ทางที่ตั้งใจไว้คือทำ **digest ย่อ** จาก report
ที่ทุก controller publish ไว้ใน `getgenv()` อยู่แล้ว:

```
AnimeOriginFastModeReport      AnimeOriginUnitProgressionReport
AnimeOriginInGameSettingsReport  AnimeOriginAutoPlayReport
AnimeOriginMain                AnimeOriginLifecycle
```

**ข้อจำกัดด้านความปลอดภัย**: repo `Pexchzq/Anime-Origin` เป็น **PUBLIC** (ยืนยันแล้ว
ว่าดึงไฟล์ได้ HTTP 200 โดยไม่ต้องมี token) และ client ~54 ตัว auto-execute
`Loader.lua` จาก repo นี้ ดังนั้น:

- ห้ามใส่ GitHub token ลงในไฟล์ใดๆ ใน repo นี้ หรือใน Lua ที่ Loader ดาวน์โหลด
  token ที่หลุด = ใครก็แก้ `Loader.lua` แล้วสั่งรันโค้ดบนทั้งฟาร์มได้
- log มี Roblox UserId ห้าม commit ลง public repo
- ถ้าจะเก็บ log ลง git ต้องเป็น repo **PRIVATE แยกต่างหาก** และ push จากฝั่ง Windows
  ด้วย credential ที่เก็บใน Windows Credential Manager ไม่ใช่จากในสคริปต์

---

## ไม่ใช่บั๊กของเรา

อาการสองอย่างนี้โผล่ตอนเครื่องโหลดหนัก อย่าเสียเวลาไล่แก้ในโค้ดนี้:

- `worm is not a valid member of ...PetsFolder.Toji_Evolved`
  `Yato Sword is not a valid member of ...PetsFolder.Yato`
  — error ของตัวเกมเอง
- `matchmaking-api/v1/client-status: HTTP 429 (Too Many Requests)`
  — Roblox rate-limit เครื่องที่เปิด client พร้อมกันมากเกินไป
  jitter ใน Loader ช่วยลดการชนกันได้ แต่ลบปัญหานี้ไม่ได้

---

## ทฤษฎีที่พิสูจน์แล้วว่าผิด (อย่าลองซ้ำ)

### ยิง `StartSelection` ตรงๆ โดยไม่เข้า Pod

`Config.main.preferDirectSelection` ตั้งบนสมมติฐานว่ารีโมตนี้รับได้เลย
ผลจริง: เซิร์ฟเวอร์ปฏิเสธ **26 จาก 26 ครั้ง** ไม่มี `AfterMapSelect` และไม่มี
`MapSelect` ใดๆ — บนไอดีเดียวกันและ session เดียวกับที่การเดินเข้า Pod ก็ล้มทั้ง 8 ประตู

ค่าเริ่มต้นจึงเป็น `false` และเก็บคีย์ไว้พร้อมคอมเมนต์เพื่อไม่ให้มีใครลองใหม่
สิ่งที่ใช้ได้จริงคือ `firetouchinterest` บน `DoorUIPart` (ดู README หัวข้อ
"การเข้า Story Pod")
