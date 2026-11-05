# Модуль `cami` — права из админок через CAMI

Мост между привилегиями Next-City ([`permissions`](../../../../../docs/ARCHITECTURE.md#6-платформа-l1)) и админками — ULX, SAM и другими, которые поддерживают общий интерфейс CAMI. Привилегии гейммода появляются в админке рядом с её командами, и решает она. Без админки модуль ничего не делает: права определяют уровни привилегий (`nc_privileges`).

| | |
|---|---|
| Интерфейс | — (только сервер) |
| Зависимости | — (глобальная таблица `CAMI` админки, если она есть) |
| Слушает | `permissions.can`, `permissions.registered`, `permissions.unregistered`, `gm.InitPostEntity` |
| Хуки | `CAMI.PlayerUsergroupChanged`, `CAMI.SteamIDUsergroupChanged` (id `nextcity.cami`) |
| Команды | `nc_cami` — найдена ли CAMI, кто решает, сколько привилегий отдано (админ) |
| Настройки | `ask` = `"auto"`, `register` = `true`, `prefix` = `"nextcity."`, `priority` = `0` |

## Как работает

- Каждая привилегия — объявленная в манифесте (`rounds.manage`) или админ-команда (`nc_round`) — регистрируется в CAMI как `nextcity.<id>`: `MinAccess` — её уровень с учётом `permissions.levels`, описание — из манифеста или справки команды. Админка выдаёт её группам по `MinAccess` и дальше хранит сама: ULX показывает её в XGUI и `ulx groupallow`, SAM — в правах ранга. Привилегии уровня `nobody` в CAMI не попадают.
- Проверка (`ctx.permissions:Can`, админ-команды) спрашивает `CAMI.PlayerHasAccess(ply, "nextcity.<id>", nil, target, { Fallback = level })`. Ответ админки окончательный: она может и выдать, и запретить. Цель передаётся, только если это игрок.
- `ask = "auto"` — спрашивать, только пока на `CAMI.PlayerHasAccess` подписана админка: одна CAMI без админки сравнила бы `MinAccess` с `IsAdmin` и не знала бы `permissions.groups`. `"always"` — спрашивать всегда, `"never"` — только регистрировать привилегии.
- Админка переводит игрока в другую группу (`ulx adduser`) и сообщает CAMI — на следующем тике клиент получает новый список привилегий. Изменение прав группы (`ulx groupallow`) CAMI не сообщает: сервер проверяет по-новому сразу, а клиент узнаёт за `permissions.refresh` секунд.
- Привилегии модулей, которые запускаются и останавливаются на ходу, регистрируются и снимаются вместе с ними. CAMI, появившаяся позже гейммода, подхватывается в `InitPostEntity`.
- Сбой CAMI (админка не ответила сразу, ошибка) — предупреждение в лог (первые 5) и ответ по уровням. Админка, которая во время ответа сама спрашивает Next-City, получает ответ по уровням.
- Выключить: `modules.disabled.cami = true`. `prefix` меняет имена в админке (ULib приводит их к нижнему регистру, id привилегий и так в нижнем), `priority` — очередь среди источников `permissions.can`.

## Своя админ-панель

Next-City не завязан на CAMI. Своя панель — обычный модуль, который отвечает на тот же вопрос шины раньше адаптера:

```lua
ctx:On("permissions.can", function(ply, id, target, privilege)
	local rank = panel:RankOf(ply)                 -- своё хранилище рангов
	if rank ~= nil then
		return rank:Allows(id, target)             -- true / false; nil — решают следующие
	end
end, { priority = 100 })                           -- cami отвечает с priority = 0
```

Список для интерфейса — `ctx.permissions:List()` (id, модуль, уровень, описание) и события `permissions.registered` / `permissions.unregistered`; после изменения прав — `ctx.permissions:Refresh(ply)`, чтобы клиент узнал сразу. Модуль `cami` при этом можно выключить или оставить для ULX и SAM.

## Проверить в реальном GMod

- ULX: `nextcity.*` в XGUI → Groups; `ulx groupallow admin nextcity.nc_round` и `ulx groupdeny` сразу действуют на команды; после `ulx adduser <ник> admin` клиент получает права без переподключения.
- SAM: привилегии в правах ранга, смена ранга игрока.
- В логе один раз `CAMI <версия>: admin mods decide the privileges`, `nc_cami` показывает хук админки.
