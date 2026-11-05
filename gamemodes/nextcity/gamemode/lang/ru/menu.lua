-- Строки меню игрока (F1): ключи "menu.<ключ>".
return {
	title = "Меню игрока · {key}",
	failed = "Вкладка не открылась, подробности в консоли",
	key = "Это меню: профиль, настройки и справка",
	["tab.settings"] = "Настройки",
	["tab.help"] = "Справка",
	["settings.language"] = "Язык",
	["settings.auto"] = "Авто — как язык игры",
	["settings.forced"] = "Сервер показывает всем один язык: {language}",
	["settings.console"] = "То же в консоли: nc_language auto, en, ru...",
	["help.keys"] = "Клавиши",
	["help.chat"] = "Чат — пишется в строке чата (Y)",
	["help.commands"] = "Команды — вводятся в консоли (~)",
	["help.admin"] = "Команды администратора",
	["help.loading"] = "Запрос к серверу...",
	["help.unbound"] = "не назначена",
}
