# Known Issues

สถานะ ณ commit `bde3928` ทุกข้อในนี้ตรวจกับซอร์สจริงแล้ว ไม่ใช่การคาดเดา
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
| `main.lua` `waitForBootstrapWorkers` | worker ตายเงียบ = PENDING ตลอด → รอ 300s | `startupGrace` (45s) → นับเป็น FAILED |
| `Loader.lua` | รอเกมโหลดก่อน arm `queue_on_teleport` | arm ก่อน แล้วรอแบบมีขอบเขต 120s |

**ตัวที่หนักที่สุดคือข้อแรก** — Pod อยู่ใต้ `MainFolder.Lobby.MapSelectors.Story` ซึ่งบนเครื่อง
ที่โหลดหนักจะยัง replicate ไม่เสร็จในไม่กี่วินาทีแรกหลัง join โค้ดเดิม `return` ทันที ทำให้
เผา transition attempt ครบ 6 ครั้ง **และ** route restart ครบ 3 ครั้ง **ก่อนที่ Pod จะมีตัวตน**
สุดท้าย route ตาย ตัวละครยืนนิ่งอยู่บนแมพที่โหลดเสร็จไปแล้วไม่กี่วินาทีหลังจากนั้น

---

## บั๊กที่ยืนยันแล้วและยังไม่แก้

### worker ที่ค้างกลางทางยังตรวจไม่ได้

`startupGrace` จับได้เฉพาะ worker ที่ **ตายก่อนจะ publish อะไรเลย** ถ้า worker publish
`RUNNING` แล้วค่อยค้าง (infinite loop) หรือตายด้วย runtime error ดิบระหว่างบรรทัด 124–1439
สถานะจะค้างที่ `RUNNING` ซึ่งไม่ terminal → main ยังรอครบ 300s เหมือนเดิม

**แก้ยังไง**: ให้ฟังก์ชัน `log()` ของแต่ละ worker ประทับ heartbeat ลง lifecycle entry แล้วให้
main ถือว่า `RUNNING` ที่ heartbeat ค้างเกิน N วินาที = ตาย เป็นการแก้ที่ครอบคลุมทั้ง
"ตาย" และ "ค้าง" แต่ต้องแตะ log path ของทั้งสอง worker จึงเลื่อนไว้ก่อนจนกว่าชุดนี้จะยืนยันแล้ว

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
ควรแคชลงดิสก์แล้วดาวน์โหลดใหม่เฉพาะเมื่อไฟล์เปลี่ยน

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
