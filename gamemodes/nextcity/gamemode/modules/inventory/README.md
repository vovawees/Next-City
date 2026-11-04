# Модуль `inventory` — инвентарь

Предметы, контейнеры, сумки, вещи на земле, ящики и тела, которые можно обыскать, и экран инвентаря. Определения предметов приходят из пакетов контента; экземпляры живут только на сервере. Клиент получает снимки контейнеров, которые видит, и отправляет намерения (переложить, взять, выбросить), а сервер их проверяет (решение D18).

| | |
|---|---|
| Интерфейс | `inventory` |
| Зависимости | `players`; необязательно `notices` (причины отказа), `ragdoll` (вещи остаются на теле) |
| Слушает | `players.spawned`, `players.loadout` (первым: опустошает контейнеры), `players.left`, `players.died` (первым), `ragdoll.corpse`, `net.ready`, `gm.PlayerUse`, `gm.EntityRemoved`; на клиенте `gm.PlayerBindPress`, `gm.HUDPaint`, `i18n.changed` |
| Спрашивает | `inventory.place (ply, item, def) -> container, slot` — куда положить полученное раньше карманов (так снаряжение забирает то, что надевается); `inventory.canMove (ply, item, from, to) -> false` — запретить перемещение |
| Испускает | `inventory.changed (container, owner)` раз в тик, `inventory.moved`, `inventory.used (ply, item, verb, c)`, `inventory.opened`, `inventory.picked (ply, id, count)`, `inventory.dropped (ply, item, ent)`; на клиенте `inventory.updated (id, c, new)`, `inventory.closed (id)`, `inventory.screen (open)` |
| Сеть | `contents`, `closed` (сервер → клиент); `move`, `act`, `close` (клиент → сервер, с лимитами частоты) |
| Компоненты | `ground` (всем): что лежит на земле; `place` (всем): вид, заголовок и имя контейнера сущности |
| Команды | `nc_items [фильтр]`, `nc_inv [игрок]`, `nc_item <игрок> <id> [кол-во]`; на клиенте `nc_inventory` |
| Настройки | `pockets` = 8 слотов, `reach` = 110 единиц, `useDelay` = 0.3 с, `maxGround` = 400, `dropDistance` = 36, `maxDepth` = 3, `corpses` = true, `bagModel` |
| Переводы | `lang/<код>/inventory.lua`; названия предметов — ключи `items.<id>` из пакетов |

## Предметы

Пакеты регистрируют предметы в `Init` своего модуля на обоих realm в одном порядке:

```lua
local inventory = ctx:Require("inventory")
inventory:RegisterItem("bandage", {
	name = "items.bandage",            -- ключ названия (по умолчанию items.<id>)
	description = "items.bandage.desc", -- ключ описания (необязательно)
	model = "models/...",              -- модель на земле и иконка
	weight = 0.1,                      -- кг за штуку
	stack = 5,                         -- сколько в одном слоте
	size = 1,                          -- 1 мелкое (карманы), 2 среднее (сумки), 3 крупное
	category = "medical",              -- weapon, ammo, medical, armor, gear, tool, food, valuable, misc
	traits = { medical = { treatment = "bandage", time = 3 } }, -- данные других модулей
})
inventory:Def(id); inventory:Items(); inventory:Trait(id, "medical"); inventory:WithTrait("ammo")
inventory:Name(id); inventory:Description(id); inventory:WeightOf(id, count)
```

Экземпляр — `{ uid, id, count, state }`; `state` — свободные данные модулей, из которых экран показывает `charge` (число: патроны, заряды), `cond` (0..1, износ) и `label` (короткий текст). Одинаковые предметы без `state` складываются в стопку.

Предмет с чертой `container = { slots, maxWeight, maxSize }` — сумка: у неё свой контейнер (`item.sub`). Вес содержимого считается выше по цепочке, сумка не кладётся в саму себя, глубина вложенности — `maxDepth`.

## Контейнеры и игроки

```lua
local crate = inventory:CreateContainer({ kind = "crate", size = 12, maxWeight = 40, maxSize = 3,
	title = "loot.crate", Accepts = function(c, slot, item, def) return true end,
	OnInsert = fn, OnRemove = fn, OnChange = fn, slotNames = { "head" } })
inventory:Give(ply or crate, "bandage", 3, state, { drop = true }) -- -> выдано, причина
inventory:Take(ply or crate, "ammo_9x19", 30)                      -- -> взято (сначала малые стопки)
inventory:Count(ply or crate, id); inventory:ItemsOf(ply or crate)
inventory:Transfer(from, fromSlot, to, toSlot, count)              -- без проверок игрока
inventory:Move(ply, fromId, fromSlot, toId, toSlot, count)         -- с проверкой досягаемости
inventory:Act(ply, containerId, slot, verb, count)                 -- глагол; слот 0 + "take_all"
inventory:Pockets(ply); inventory:AddOwned(ply, c, order); inventory:Owned(ply); inventory:Own(ply)
inventory:Load(ply); inventory:Clear(ply); inventory:Carries(ply)
```

- У каждого игрока карманы (`pockets` слотов, только мелкое) и контейнеры, которые дают другие модули (`AddOwned`: снаряжение). Свои контейнеры и сумки в них игрок видит всегда, чужие — пока они открыты и в досягаемости.
- Изменения уходят раз в тик: снимок каждого изменённого контейнера тем, кто его видит. Ботам ничего не отправляется.
- Причины отказа: `container`, `reach`, `empty`, `same`, `slot`, `size`, `accepts`, `weight`, `cycle`, `depth`, `occupied`, `full`, `denied`, `verb`, `drop`. Игрок видит уведомление `inventory.fail.<причина>`.

## Глаголы

```lua
inventory:RegisterVerb("use", { label = "medical.verb.use", order = 5,
	Applies = function(item, def, where, kind) return def.traits.medical ~= nil end }) -- оба realm
inventory:HandleVerb("use", function(ply, item, container, count) return true end) -- сервер
```

`where` — `"own"` (свои контейнеры) или `"external"` (чужие). `kind` — вид контейнера, где лежит предмет (`pockets`, `equipment`, `bag`, `crate`…). Встроенные: `take`, `open` (сумка в чужом контейнере), `split`, `drop`.

## Мир

- `SpawnItem(item, pos, ang)` кладёт предмет на землю пропом его модели; клавиша использования подбирает, что не влезло — остаётся. Не больше `maxGround` вещей, старые исчезают первыми.
- `SpawnPlace(pos, ang, spec)` / `AttachPlace(ent, spec)` — сущность с контейнером (ящик, тайник); клавиша использования открывает его. `DetachPlace(ent)`, `PlaceOf(ent)`, `ItemOf(ent)`.
- Мёртвые оставляют вещи на теле (`ragdoll.corpse`), а без тела — в мешке на месте смерти, который исчезает, когда опустеет. `Bury(ply, ent, spec)` — переложить всё в контейнер на сущности.
- Удаление сущности уничтожает её предмет или контейнер со всем содержимым.

## Клиент

Экран — клавиша контекстного меню (C) или `nc_inventory`; открывается сам, когда игрок что-то обыскивает. Слева свои контейнеры (снаряжение, карманы, сумки), справа открытые чужие.

| Действие | Результат |
|---|---|
| Перетащить слот на слот | переложить стопку (Shift — половину, Ctrl — одну), разные вещи меняются местами |
| Перетащить на заголовок | в первый подходящий слот контейнера |
| Перетащить на пустую правую часть | положить на землю |
| Правая кнопка | глаголы предмета и «Переложить в» |
| Двойной щелчок | взять (из чужого) или первый глагол предмета |

Под прицелом — название вещи на земле или места и клавиша: «E — поднять», «E — обыскать».

```lua
local inventory = NC.Module("inventory") -- на клиенте
inventory:Own(); inventory:External(); inventory:Get(id); inventory:Count(id); inventory:Spend(id, n)
inventory:OpenScreen(); inventory:CloseScreen(); inventory:ToggleScreen(); inventory:IsScreenOpen()
```

## Проверить в реальном GMod

- Перетаскивание (`Droppable`/`Receiver`) и иконки `ModelImage` на разных разрешениях.
- Трассировка подсказки по рэгдоллам тел (маска `MASK_SHOT`) и вещам с `COLLISION_GROUP_WEAPON`.
- Подбор клавишей E сквозь `GM:PlayerUse` при зажатой клавише (задержка `useDelay`).
