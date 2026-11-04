# Модуль `players` — жизненный цикл игрока

Кто загружается, наблюдает, жив или мёртв; ввод игрока в игру и выбор точки появления. Раунды и режимы строятся поверх него и не трогают `ply:Spawn()` напрямую.

| | |
|---|---|
| Интерфейс | `players` |
| Зависимости | нет |
| Слушает | `gm.PlayerInitialSpawn`, `net.ready`, `gm.PlayerSpawned`, `gm.PlayerLoadout`, `gm.PlayerDeath`, `gm.PlayerSilentDeath`, `gm.PlayerDisconnected`, `gm.InitPostEntity`, `gm.PostCleanupMap` |
| Отвечает | `gm.PlayerSpawn`, `gm.PlayerSelectSpawn`, `gm.PlayerDeathThink`, `gm.PlayerShouldTakeDamage` (только во время `Kill`) |
| Испускает | `players.ready`, `players.stateChanged`, `players.loadout`, `players.spawned`, `players.died`, `players.left` |
| Спрашивает | `players.spawnPoint (ply)` → сущность, `{ pos, ang }`, группа (`"a"`, `"b"`, `"any"`) или `nil` |
| Компоненты | `life` игрока (`state`, `respawnAt`), реплицируется всем 10 раз в секунду |
| Команды | `nc_players` — игроки и их состояния |
| Настройки | `clearance` = 40 — точка занята, пока ближе стоит живой игрок |

## Состояния

`connecting` → `spectator` → `alive` ⇄ `dead`; из любого готового состояния — `spectator`.

- `connecting` — клиент ещё загружается (боты пропускают это состояние).
- `spectator` — готов, но не в игре (наблюдатель).
- `alive` — в игре; `dead` — умер и остаётся мёртвым, пока его снова не введут в игру.

В игру попадают только через `Deploy`: любое другое появление (первое появление движка, автовозрождение базового режима) делает игрока наблюдателем.

## API (сервер)

- `M:Deploy(ply, { spawn = точка })` — ввести готового игрока в игру (живого — переродить); `true`, если он жив.
- `M:MakeSpectator(ply)` — вывести из игры: тихая смерть и наблюдатель.
- `M:SetRespawnAt(ply, время)` — показать клиентам, когда мёртвый вернётся (`nil` — сбросить).
- `M:Kill(ply, { attacker, inflictor, damageType, force, position })` — смерть от имени атакующего (D6: когда умирать, решает модель тела, движок только исполняет): урон движка, который никто не может отклонить, поэтому фраги, килфид и регдолл достаются атакующему. Недействительные атакующий и оружие заменяются миром; если движок всё же не убил (режим бога) — `ply:Kill()`. `M:IsKilling(ply)` — идёт ли сейчас такой урон (обработчики урона его пропускают).
- `M:State(ply)`, `M:IsAlive(ply)`, `M:IsReady(ply)`, `M:RespawnAt(ply)` — то же доступно на клиенте.
- `M:List(state)`, `M:Count(state)`, `M:ReadyPlayers()`.
- `M:SpawnPoints(group)`, `M:PickSpawn(ply, кандидаты)` — свободная точка подальше от противников, при равенстве по кругу; если все заняты — свободное место рядом с точкой.
