# Модуль `rounds` — раунды, режимы и правила

Автомат раунда, реестр режимов и блоков правил, типизированные параметры режимов (D9, [ARCHITECTURE §11](../../../../../docs/ARCHITECTURE.md#11-режимы-l3)). О конкретных режимах модуль ничего не знает: режим — отдельный модуль, который регистрируется здесь.

| | |
|---|---|
| Интерфейс | `rounds` |
| Зависимости | `players` |
| Слушает | `players.ready`, `players.spawned`, `players.loadout`, `players.died`, `players.left`, `net.ready` |
| Отвечает | `players.spawnPoint`, `gm.PlayerShouldTakeDamage` |
| Испускает | `rounds.phase (phase, old, round)` — на сервере и на клиенте |
| Сеть | `state` (фаза, режим, номер, конец фазы), `result` (итог раунда) |
| Команды | `nc_round` (админ), `nc_modes` (все) |
| Переводы | `lang/<код>/rounds.lua` |

## Фазы

`waiting` → `preparing` → `active` → `ended` → `preparing` → …; из любой фазы — `waiting`.

- **waiting** — игроков меньше `minPlayers` режима. Разминка: все готовые игроки в игре, умершие возвращаются через `warmupRespawn` секунд, урон есть.
- **preparing** — очистка карты, новый раунд: `Setup`, участники (`Participants`) получают `PlayerAdded` и появляются, остальные — наблюдатели. Участники заморожены, урона нет, через `prepareTime` — старт. Если игроки ушли и их меньше `minPlayers` — обратно в `waiting`.
- **active** — `Start`, `Think` с частотой режима, смерти, возрождения, лимит времени, проверка победы (`CheckWin` после смертей и уходов, не чаще раза за тик). Ушли все участники — итог `abandoned`.
- **ended** — `End` с итогом, баннер у клиентов, урона нет; через `endTime` — `Cleanup` и следующий раунд (или `waiting`).

## Режим

```lua
function M:Init(ctx)
	ctx:Require("rounds"):RegisterMode({
		id = "tdm",
		name = "mode_tdm.name",          -- ключ перевода или текст
		minPlayers = 2,
		thinkRate = 2,                    -- Think, раз в секунду
		rules = { "time_limit", "respawn" },
		params = { roundTime = { type = "number", default = 600, min = 60, max = 3600 } },
		Loadout = function(round, ply) ply:Give("weapon_crowbar") end,
		CheckWin = function(round) end,   -- итог или nil
	}, ctx)                               -- режим уходит вместе с модулем
end
```

Неизвестные ключи — ошибка (опечатка в имени колбэка не пройдёт молча).

**Колбэки-уведомления** (сначала правила по порядку, затем режим): `Setup`, `PlayerAdded(ply)`, `Start`, `Think`, `PlayerSpawned(ply)`, `Loadout(ply)`, `PlayerDied(ply, inflictor, attacker)`, `PlayerLeft(ply)`, `End(result)`, `Cleanup` (всегда после `Setup`, в том числе при прерывании).

**Вопросы** (сначала режим, затем правила; побеждает первый ответ не `nil`): `Participants(ready)`, `LateJoin(ply)` (по умолчанию — только во время подготовки), `SpawnPoint(ply)` (как ответ на `players.spawnPoint`), `CheckWin()`, `Timeout()` (по умолчанию `{ reason = "time" }` — ничья), `ShouldTakeDamage(ply, attacker)`.

Ошибка в колбэке пишется в лог с именем режима или правила, раунд продолжается.

## Объект раунда

- `round.number`, `round.mode`, `round.name`, `round.params` (проверенные значения), `round.data` (данные режима), `round:RuleData(id)` (данные правила), `round.startedAt`, `round.endsAt`, `round.result`.
- `round:On`, `Every`, `After`, `Defer` — подписки, задачи и таймеры, которые снимаются вместе с раундом.
- `round:Participants()`, `ParticipantCount()`, `IsParticipant(ply)`, `Alive()`, `AliveCount()`, `AddParticipant(ply)`.
- `round:Respawn(ply, delay)`, `CancelRespawn(ply)`, `IsRespawning(ply)`, `RespawnCount()` — клиенты видят время возрождения (`players.life.respawnAt`).
- `round:SetTimeLimit(seconds)`, `TimeLeft()`, `Elapsed()`, `Phase()`, `IsActive()`.
- `round:CheckWin()` — проверить победу на следующем тике; `round:End(result)` — `{ reason, team, winner, key }` и свои поля режима.

## Встроенные правила

| Правило | Параметры | Что делает |
|---|---|---|
| `time_limit` | `roundTime` = 300 (0 — без лимита) | конец раунда по времени |
| `respawn` | `respawn` = `instant` \| `wave` \| `none`, `respawnDelay` = 5, `waveInterval` = 15 | возрождение участников; опоздавшие входят в идущий раунд |
| `last_standing` | — | каждый сам за себя: побеждает последний живой |
| `silent_deaths` | — | смерти не объявляются: ни ленты убийств, ни строки в консоли (`gm.PlayerDeathNotice`) |
| `dead_mute` | — | живые не слышат мёртвых и наблюдателей: ни чат, ни голос |

Режим может объявить параметр правила у себя, чтобы поменять значение по умолчанию.

## Параметры и настройки

Значения раунда: значения по умолчанию → `params[режим]` из настроек → `nc_round param` из консоли. Неверный тип заменяется значением по умолчанию, выход за границы ограничивается — с предупреждением в логе (один раз).

```lua
-- config.lua
settings = {
	rounds = {
		mode = "tdm",
		rotation = { "tdm", "homicide" }, roundsPerMode = 3,
		prepareTime = 5, endTime = 8,
		params = { tdm = { roundTime = 900 } },
	},
},
```

Остальные настройки: `freeze`, `shuffle`, `cleanupMap`, `warmup`, `warmupRespawn`, `warmupLoadout` — см. `module.lua`.

## Консоль

- `nc_round` — состояние раунда, параметры, следующий режим.
- `nc_round restart [режим]` — новый раунд сейчас, при любом числе игроков.
- `nc_round end` — завершить раунд (ничья).
- `nc_round next <режим>` — режим следующего раунда.
- `nc_round param <режим> <имя> [значение]` — переопределить параметр со следующего раунда; без значения — сбросить.
- `nc_modes` — режимы, их правила и параметры с текущими значениями.
