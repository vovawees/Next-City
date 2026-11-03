# Модуль `example` — шаблон

Минимальный модуль, на котором виден весь контракт: манифест, файлы по realm, жизненный цикл, подписки и задачи через `ctx`. По умолчанию выключен: чтобы включить, уберите `example = true` из `modules.disabled` в `config.lua`.

| | |
|---|---|
| Интерфейс | `example` |
| Зависимости | нет |
| Слушает | `gm.PlayerInitialSpawn` (сервер), `gm.InitPostEntity` (клиент) |
| Задачи | `example:heartbeat` каждые `interval` секунд (сервер) |
| Настройки | `interval` = 5, `greeting` = `"Welcome to Next-City"` |
| API | `M:Greeting(name)` |

## Как сделать свой модуль

1. Скопируйте папку в `modules/<id>/`; `id` в `module.lua` должен совпадать с именем папки.
2. Укажите `provides`, `requires`, `optional` и файлы по realm (`sh`, `sv`, `cl`).
3. Каждый файл начинается с `local M = NC.Module("<id>")`, всё остальное — `local`.
4. Подписки, задачи и таймеры — только через `ctx:On`, `ctx:Every`, `ctx:After`: они снимаются автоматически при остановке.
5. Проверьте: `nc_modules` в консоли сервера и `luajit tests/run.lua`.
