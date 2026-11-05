# Модуль `profiles` — профили и статистика игроков

Что сервер помнит о каждом игроке между заходами: первый и последний визит, время в игре, число визитов, статистику и разделы других модулей (персонаж, внешность). Одна запись на игрока (SteamID64) в коллекции `storage`; свою сводку игрок видит во вкладке «Профиль» меню F1.

| | |
|---|---|
| Интерфейс | `profiles` (сервер; сводка — оба realm) |
| Зависимости | необязательные: `storage` (без него — только на сессию), `menu` (вкладка «Профиль») |
| Слушает | `gm.PlayerInitialSpawn`, `gm.PlayerDisconnected`, `gm.ShutDown` (раньше `storage`), `players.died`, `npcs.killed`, `rounds.phase` |
| Испускает | `profiles.loaded (ply, record, isNew)`, `profiles.leaving (ply, record)`, `profiles.stat (ply, name, value, amount)` |
| Спрашивает | `profiles.won (ply, result, round)` → `true` / `false` |
| Компоненты | `summary` (владельцу, 1/с): `first`, `visits`, `playtime`, `since`, `kills`, `deaths`, `rounds`, `wins`, `creatures` |
| Права | `profiles.view` (admin) — чужие профили в `nc_profile` |
| Команды | `nc_profile [игрок \| steamid64]` (свой — всем) |
| Настройки | `collection` = `"profiles"`, `saveInterval` = 60 с, `bots` = `false` |

## Запись

```lua
{
	v = 1,                      -- версия формата
	name = "Bob",               -- последний ник
	first = 1700000000,         -- unix-время первого визита
	last = 1700003600,          -- последний вход или выход
	visits = 12,
	playtime = 54000,           -- секунд в игре
	stats = { kills = 3, deaths = 5, rounds = 9, wins = 2, creatures = 40, arrests = 1 },
	sections = { identity = { ... }, appearance = { ... } },
}
```

## API

```lua
local profiles = ctx:Require("profiles")      -- в манифесте: optional = { "profiles" }
local record = profiles:Get(ply)              -- запись игрока на сервере или nil
local mine = profiles:Section(ply, "mymod")   -- таблица раздела модуля (создаётся пустой)
mine.level = 3
profiles:Touch(ply)                           -- запишется через flushDelay storage
profiles:AddStat(ply, "arrests", 1)           -- счётчик stats.<имя>, вернёт новое значение
profiles:Stat(ply, "kills"); profiles:Playtime(ply)
profiles:Key(ply)                             -- ключ storage: SteamID64, "bot_<имя>"
profiles:ByKey("76561198000000001")           -- запись любого игрока (в том числе ушедшего)
profiles:Save(ply)                            -- посчитать время и записать сразу
profiles:Summary(ply)                         -- сводка (клиент: только своя)
profiles:SummaryPlaytime(ply)                 -- время в игре с текущей сессией
profiles:FormatPlaytime(seconds)              -- клиент: «5 ч 12 мин», как во вкладке
```

- Свои данные модуль читает на `profiles.loaded`, меняет и вызывает `Touch`; последнее слово — на `profiles.leaving` (запись выгружается сразу после).
- Победа в раунде: ответ `profiles.won`, иначе `result.winner == ply` или `result.team == ply:Team()`. Режимы без победителя-игрока и команды (CO-OP, Defense) отвечают сами.
- Боты — только на сессию (`bots = true` сохраняет и их).

## Вкладка «Профиль»

Первая вкладка меню F1 (модуль [`menu`](../menu/README.md)): ник, первый визит, число визитов, время в игре и статистика — убийства, смерти, сыгранные раунды, победы, убитые существа. Вкладка пересобирается, когда меняется сводка или минута времени в игре.

## Проверить в реальном GMod

- Файлы `data/nextcity/profiles/<steamid64>.json` после захода, выхода и перезапуска; время в игре после `saveInterval` и выключения сервера.
- Бэкенд `sqlite`: таблица `nextcity_profiles` в `sv.db`.
- `nc_profile` у игрока (своя запись) и у админа (чужая, в том числе ушедшего игрока по SteamID64).
- Вкладка «Профиль» в F1: цифры совпадают с `nc_profile`, время в игре растёт, пока меню открыто.
