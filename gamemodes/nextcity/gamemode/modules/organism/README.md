# Модуль `organism` — модель тела

Полная модель тела (D6, D11): попадания становятся ранами, переломами, повреждёнными органами, нервами и изменениями дыхания; кровь и кровообращение, дыхание, мозг, боль, шок, сознание, выносливость, температура и препараты симулируются, а смерть решает мозг. HP движка не используется. Потребители (движение, оружие, HUD) читают только возможности и показатели, никогда — внутреннее состояние.

| | |
|---|---|
| Интерфейс | `organism` |
| Зависимости | `players` |
| Слушает | `players.spawned` (новое тело), `players.died` (убит не телом), `players.left`, `players.stateChanged` (вне игры тела нет), `gm.KeyPress` (прыжок тратит выносливость), `net.succumb`; клиент: компонент `vitals`, `gm.PlayerBindPress` |
| Испускает | `organism.wounded (ply, hit, report)`, `organism.treated (ply, kind, opts)`, `organism.unconscious (ply, bool)`, `organism.capabilities (ply, caps)`, `organism.died (ply, cause, killer)`; клиент: `organism.vitals (ply, vitals, mask)`, `organism.capabilities (ply, caps)` |
| Спрашивает | `organism.canSuccumb (ply)` → `false` не даёт сдаться (например, режим с медиками) |
| Компоненты | `vitals` игрока — только владельцу, 10 раз в секунду (кровь, кровотечение, пульс, SpO2, боль, выносливость, сознание, температура, множители движения и прицеливания, эффекты зрения, флаги возможностей и состояний) |
| Команды | `nc_organism [игрок]`, `nc_hurt <игрок> <вид> [часть] [сила]`, `nc_heal [игрок]`, `nc_treat <игрок> <вид> [конечность \| сторона \| область \| доза]` |
| Настройки | `rate` = 10 шагов в секунду; `bloodVolume` = 5000 мл; `brainDeathTime` = 300 с без кислорода; `bleedScale` = 1; `painScale` = 1; `sprintTime` = 12 с; `succumbDelay` = 5 с (−1 — сдаваться нельзя); `maxWounds` = 48 |

## Как устроено

- **Тело** (`sv_body.lua`) — данные: 15 сегментов с системами координат из костей ValveBiped и 77 структур (органы, кости, сосуды, нервы, дыхательные пути, мягкие ткани) из капсул и сфер. Пуля — луч через структуры, теряющий энергию; где формы пересекаются, путь забирает структура с большим приоритетом. Модели без этих костей используют эталонный скелет, повёрнутый по взгляду игрока. Пока тело несёт другая сущность (регдолл, `SetCarrier`), кости берутся у неё.
- **Травмы** (`sv_injuries.lua`) — `Injure(ply, hit)` превращает попадание в раны (источники кровотечения и боли), повреждения органов, переломы, вывихи, разрывы нервов, пневмоторакс. Мгновенная смерть — только от разрушения мозга/ствола, массивной травмы, падения или взрыва.
- **Физиология** (`sv_physiology.lua`) — тело продвигается шагами по ~0,1 с через упорядоченный список заменяемых шагов: `drugs` → `bleeding` → `circulation` → `respiration` → `brain` → `neuro` → `consciousness` → `stamina` → `temperature`. Раны кровоточат по давлению и сворачиваются сами до предела, зависящего от размера; кровь заполняет полости (гемоторакс, тампонада, гематома в черепе). Сердце может фибриллировать или остановиться (ЭМД, асистолия), лёгкие спадаются, клапанная утечка даёт напряжённый пневмоторакс. Мозг получает кислород по перфузии, насыщению и гемоглобину; без него погибает за `brainDeathTime`.
- **Расписание** — тела обходятся по кругу, `rate` раз в секунду каждое, равномерно по тикам (128 игроков — ~20 тел за тик, 2–5 мкс на тело). Травмы и лечение действуют сразу.
- **Смерть** — когда тело умирает, `players:Kill` убивает игрока от имени того, кто нанёс больше всего травм (килфид, фраги, регдолл). Если игрока убило что-то другое, тело помечается мёртвым (`cause = "killed"`).
- **Сдаться** — без сознания дольше `succumbDelay` игрок может нажать перезарядку и умереть сразу (если `organism.canSuccumb` не против).

Причины смерти: `head`, `brain`, `brainstem`, `trauma`, `fall`, `blast`, `burns`, `succumb`, `killed`.

## Возможности и показатели

`Capabilities(ply)` — одинаковая таблица на сервере (у каждого тела) и на клиенте (только у своего): `alive`, `unconscious`, `canStand`, `canJump`, `canSprint`, `canUseArmL`, `canUseArmR`, `moveSpeedMul` (0..1), `aimSway` (0..1), `recoilMul` (1..3), `visionBlur` (0..1). Не изменять.

`Vitals(ply)` — значения компонента `vitals`; `M.HasStatus(vitals, имя)` проверяет флаг состояния из `M.STATUS_ORDER` (в порядке важности для HUD): `unconscious`, `arrest`, `heavyBleeding`, `bleeding`, `breathless`, `shock`, `pain`, `paralysis`, `fractureArmL/ArmR/LegL/LegR/Ribs/Pelvis/Spine/Skull`, `dislocation`, `concussion`, `burns`, `poisoned`, `cold`, `exhausted`, `tourniquet`, `bandaged`.

## API (сервер)

- `M:Injure(ply, hit)` → отчёт `{ kind, wounds, bleeding, energy, structures, fractures, fatal }` или `nil` (нет живого тела). Поля попадания (все необязательны, кроме `kind`): `attacker`, `inflictor`, `type` (DMG_*), `pos`, `dir`, `force`, `amount` (урон движка), `energy` (Дж), `projectile` (`mass` г, `velocity` м/с, `diameter` мм, `penetration` см, `expansion`, `fragment`, `fragmentFactor`), `depth` (клинок, см), `speed` (падение, юнит/с), `segment`, `toxin`, `cause`.
- Виды: `bullet`, `fragment` (луч), `stab`, `slash` (клинок), `blunt`, `crush`, `vehicle`, `fall`, `blast`, `burn`, `shock`, `stun`, `poison`, `generic`, `lethal`. `M:RegisterInjury(вид, fn(self, st, hit, report))` добавляет или заменяет вид.
- `M:ApplyTreatment(ply, вид, opts)` → `true` или `false` и причина (`dead`, `unknown`, `target`, `nothing`, `already`, `pulse`, `not_shockable`). Предметы (M6) решают, кто, когда и как долго лечит; здесь лечение действует сразу. `M:RegisterTreatment(вид, fn(self, st, opts, now))`.
- `M:Succumb(ply)` — сдаться (как по клавише); `false`, если ещё нельзя.
- `M:IsSimulated(ply)`, `M:IsDead(ply)`, `M:IsUnconscious(ply)`, `M:Capabilities(ply)`, `M:Vitals(ply)`, `M:Wounds(ply)`, `M:Describe(ply)` (строки для консоли), `M:State(ply)` (внутреннее состояние — только для отладки и тестов).
- `M:Locate(ply, ox, oy, oz, dx, dy, dz)`, `M:Cast(...)`, `M:NearestSegment(ply, x, y, z)` — геометрия попаданий (для брони и урона).
- `M:SetCarrier(ply, ent | nil)`, `M:Carrier(ply)`, `M:BodyEntity(ply)` — носитель тела: другая сущность (регдолл упавшего игрока), с костей которой читаются попадания, а голова смотрит туда же, куда глаза модели (вложение `eyes`); дыхание под водой — по голове носителя. У нового тела (каждое появление) носителя нет.
- `M:SetStep(id, fn, after)` — заменить шаг физиологии или добавить новый после `after`; `M:Steps()` — порядок шагов.

## API (клиент)

- `M:Capabilities()`, `M:Vitals()`, `M:IsUnconscious()` — только локальный игрок.
- `M:SuccumbIn()` — секунд до возможности сдаться (`0` — можно), `nil` — нельзя.

## Лечение

| Вид | Параметры | Что делает |
|---|---|---|
| `bandage` | `region` \| `limb` | давящая повязка на самую сильную наружную рану |
| `hemostatic` | `region` \| `limb` | тампонада гемостатиком, в том числе узловых ран |
| `tourniquet`, `tourniquet_off` | `limb` | останавливает кровотечение конечности ниже жгута |
| `splint` | `limb` | шина на сломанные кости конечности |
| `reduce` | `limb` | вправить вывих |
| `chest_seal` | `side` | окклюзионная повязка на сосущую рану груди |
| `needle` | `side` | игольная декомпрессия напряжённого пневмоторакса |
| `chest_tube` | `side` | дренаж воздуха и крови из плевральной полости |
| `pericardiocentesis` | — | дренаж крови из перикарда |
| `suction` | — | очистить дыхательные пути от крови |
| `cpr`, `ventilate` | — | компрессии и вдохи (каждое действует 2 с) |
| `defib` | — | разряд: может запустить фибриллирующее сердце |
| `morphine`, `naloxone`, `epinephrine`, `txa` | `dose` (1) | доза препарата |
| `saline`, `blood` | `ml` (500), `seconds` (120) | инфузия |
| `heal` | — | новое здоровое тело |

Конечности: `arm_l`, `arm_r`, `leg_l`, `leg_r`; стороны: `l`, `r` (по умолчанию — худшая).

## Консоль

- `nc_hurt Bob` — пуля в середину тела спереди; `nc_hurt Bob bullet heart`, `nc_hurt Bob slash arm_l 30`, `nc_hurt Bob fall 700`. Части: `head`, `face`, `neck`, `chest`, `heart`, `abdomen`, `liver`, `pelvis`, `back`, `arm_l`, `arm_r`, `leg_l`, `leg_r` или id структуры (`femoral_artery_l`, `lung_r`, …).
- `nc_treat Bob tourniquet leg_l`, `nc_treat Bob morphine 2`, `nc_treat Bob` — список видов.
- `nc_organism Bob` — полное состояние: кровь, сердце, дыхание, полости, раны, кости, препараты, возможности.
