# Модуль `actions` — действия со временем

Перевязка, обыск, взлом замка занимают время. У игрока одно действие за раз с полосой прогресса; действие прерывается, если игрок отошёл, ранен, потерял сознание, умер или пропала цель.

| | |
|---|---|
| Интерфейс | `actions` |
| Зависимости | `players`; необязательно `organism` (потеря сознания), `notices` (причина прерывания) |
| Слушает | `players.died`, `players.left`, `players.stateChanged`, `damage.hit`; на клиенте `gm.HUDPaint` |
| Испускает | `actions.started (ply, id)`, `actions.completed (ply, id)`, `actions.cancelled (ply, id, reason)` |
| Компоненты | `action` (владелец): ключ подписи, имя цели, начало, длительность |
| Настройки | `range` = 96, `tolerance` = 32 единицы, `interval` = 0.1 с |
| Переводы | `lang/<код>/actions.lua` |

## API

```lua
local actions = ctx:Require("actions")
local ok, reason = actions:Begin(ply, {
	id = "bandage", label = "medical.action.bandage", duration = 4,
	target = other,            -- сущность: должна существовать и быть в пределах range
	allowMove = false,         -- сдвиг больше tolerance прерывает
	allowDamage = false,       -- попадание прерывает
	Check = function(ply, target) return true end,          -- false, причина — прервать
	Tick = function(ply, target, action, now) end,         -- после каждой проверки: true — завершить сейчас
	OnComplete = function(ply, target, action) end,
	OnCancel = function(ply, reason, target, action) end,
	quiet = false,             -- true — без уведомления о прерывании
})
actions:Cancel(ply, reason); actions:Complete(ply); actions:Current(ply); actions:IsBusy(ply); actions:Progress(ply)
```

- Отказ при старте: `dead`, `unconscious`, `busy`, `target`, `range` или причина `Check`.
- Причины прерывания: `dead`, `left`, `unconscious`, `moved`, `hurt`, `target`, `range`, `cancelled` или причина `Check`. Игрок видит уведомление `actions.stopped.<причина>`, если для причины есть перевод.
- Нулевая длительность завершает действие сразу; `Complete(ply)` завершает текущее действие досрочно (`OnComplete` вызывается).
- `Tick` — работа по ходу действия (компрессии СЛР каждую секунду); `true` завершает действие.

## Клиент

Полоса внизу по центру: переведённая подпись (параметр `{target}` — имя цели: игрок или тот, чьё тело несёт сущность-цель, например регдолл упавшего) и оставшиеся секунды.

## Проверить в реальном GMod

- Прерывание при толчках физикой и на движущихся платформах (порог `tolerance`).
