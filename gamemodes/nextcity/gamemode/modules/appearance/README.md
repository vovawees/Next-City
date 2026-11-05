# Модуль `appearance` — внешность персонажа

Внешность персонажа каждого игрока в его профиле (раздел `appearance` модуля [`profiles`](../profiles/README.md)): модель из наборов, которые добавляют пакеты, её скин и бодигруппы, цвет одежды. Новичок получает случайную внешность для пола своего персонажа ([`identity`](../identity/README.md)), выбирает свою во вкладке «Внешность» меню F1 с превью и надевает её при каждом появлении — если режим не одевает его сам (форма профессий города) и не подменяет внешность (псевдонимы Homicide).

| | |
|---|---|
| Интерфейс | `appearance` (оба realm) |
| Зависимости | `players`, `profiles`; необязательные: `identity` (пол персонажа), `notices` (что вышло из смены), `menu` (вкладка «Внешность») |
| Слушает | `profiles.loaded`, `profiles.leaving`, `players.ready` и `players.spawned` (приоритет −10, после `identity`), `identity.changed`, `ragdoll.fell`, `ragdoll.corpse`; отвечает на `gm.PlayerSetModel` (приоритет −10, ниже режимов) |
| Сводит | `appearance.look (look \| nil, ply)` → другая внешность (режимы; копия, её можно менять) |
| Спрашивает | `appearance.canChange (ply, look)` → `false`: сейчас менять нельзя |
| Испускает | `appearance.changed (ply, look, old)` (`old` — `nil` для первой) |
| Компоненты | `look` (владельцу, 2/с): `model`, `skin`, `bodygroups`, `color`, `random`, `ready`; `clothes` (всем, 4/с, на рэгдолле): `color` |
| Сеть | `change` (клиент → сервер, 1/с, запас 3): `model`, `skin`, `bodygroups`, `color` |
| Команды | `nc_look [random]` (своя внешность, случайная из своих наборов), `nc_looks` (наборы) — всем |
| Настройки | `random` = `true`, `cooldown` = 10 с |

## Внешность

```lua
-- раздел appearance профиля
{ model = "models/player/group01/female_02.mdl", skin = 0, bodygroups = { 0, 1 }, color = 0x7A2E2E, random = false }
```

- **Модель** — путь в нижнем регистре с прямыми слэшами из наборов для пола персонажа (без `identity` или пола — из всех). Внешность из набора, которого больше нет, удаляется при загрузке профиля.
- **Скин и бодигруппы** — значения групп 0, 1, … (нули в конце не хранятся); надеваются, только когда на игроке модель внешности, и обрезаются до того, что у модели есть.
- **Цвет одежды** — `0xRRGGBB`, цвет игрока движка (`SetPlayerColor`) на любой модели; вкладка предлагает палитру `appearance.PALETTE` (12 цветов, первый — цвет движка) и свободный выбор.
- **Новичок** (`random`): готов к игре — получает случайную модель своих наборов в цвете палитры. Случайная внешность следует за сменой пола; своя остаётся, пока новый пол может её носить. `random = false`: внешности нет, пока игрок не выберет, на нём модель игры.
- **Своя смена** — через `cooldown` секунд после прошлой; модули запрещают смену ответом `false` на `appearance.canChange`. `Change(..., force)` — без кулдауна и вопроса.

## Наборы

Пакеты добавляют наборы в `Init` на обоих realm в одном порядке; тот же `id` заменяет набор. Официальный пакет — модуль [`wardrobe`](../../../../../lua/nextcity/README.md#внешность): горожане (`group01`, 9 мужских и 6 женских моделей) и беженцы (`group02`, 4 мужские) Half-Life 2 — модели, которые есть у каждого игрока.

```lua
appearance:AddSet("rebels_female", {
	models = { "models/player/group03/female_01.mdl", "models/player/group03/female_02.mdl" },
	gender = "female",              -- nil: всем
	title = "mypack.rebels_female", -- ключ перевода; по умолчанию appearance.set.<id>
	order = 30,                     -- порядок во вкладке; по умолчанию 100
})
```

## Кто одевает

При каждом появлении модель — ответ на `gm.PlayerSetModel`: режим, который одевает игроков сам (форма профессий города — по полу персонажа), побеждает; иначе отвечает `appearance` моделью действующей внешности — своей после сведения `appearance.look`. Затем (`players.spawned`) — скин и бодигруппы на модели внешности и цвет одежды на любой. `appearance:Dress(ply)` надевает всё на живого сразу (смена профессии в городе). Упавшее тело и труп (`ragdoll`) сохраняют цвет одежды игрока: компонент `clothes` ставит его клиентам на рэгдолл.

```lua
-- в Setup режима: у каждого внешность его псевдонима (раунд снимает ответ сам)
round:On("appearance.look", function(look, ply)
	return appearance:Pick(appearance:GenderOf(ply), aliasNumber[ply])
end)
```

## API

```lua
local appearance = ctx:Require("appearance")   -- в манифесте: optional = { "appearance" }
appearance:AddSet(id, spec); appearance:RemoveSet(id); appearance:Set(id)
appearance:Sets("female")                       -- наборы, которые может носить пол, по порядку (nil: все)
appearance:SetOf(model, gender); appearance:Allows(model, gender); appearance:Models(gender)
appearance:Pick(gender, 3)                      -- внешность № 3 из моделей и палитры: тот же номер — та же
appearance:RandomLook(gender)                   -- случайная модель в случайном цвете палитры
appearance:Look(ply)                            -- сервер: { model, skin, bodygroups, color, random } или nil
appearance:Effective(ply)                       -- то, что он носит, где режим не одевает: после appearance.look
appearance:Change(ply, look, force, random)     -- true или false, причина[, секунды]: loading, model, same,
                                                -- cooldown, denied
appearance:Request(ply, look); appearance:Randomize(ply, force); appearance:Wait(ply)
appearance:GenderOf(ply); appearance:Dress(ply)
appearance:Look(); appearance:Wait(); appearance:Ask(look); appearance:Draft()  -- клиент: своё
appearance.Pack(r, g, b); appearance.Unpack(color); appearance.ToVector(color); appearance.FromVector(v)
appearance.Normalize(path); appearance.CleanLook(look); appearance.SameLook(a, b)
```

## Вкладка «Внешность»

Третья вкладка меню F1 (после «Персонажа»): превью модели в выбранном цвете, кнопки наборов для пола персонажа, иконки их моделей, переключатели скина и бодигрупп, которые есть у модели, палитра и смеситель цвета, кнопки «Случайная», «Отменить» и «Сохранить внешность». Под превью — выдана ли внешность случайно, одевает ли сейчас режим по-своему, не сохранён ли выбор и сколько ждать до следующей смены.

## Проверить в реальном GMod

- Новичок мужского и женского пола: случайная модель своих наборов, раздел `appearance` в `data/nextcity/profiles/<steamid64>.json`; `nc_look`, `nc_look random`, `nc_looks`.
- Вкладка «Внешность»: камера и поза превью, иконки моделей и их обводка выбранной, скины и бодигруппы моделей горожан, цвет одежды на превью, на игроке и на его трупе.
- Город: горожанин в своей внешности, полиция и медики в форме своего пола, снова горожанин — снова своя; Homicide — внешности псевдонимов.
- Модель `female_05` в наборе горожанок (её нет в некоторых сборках игры).
