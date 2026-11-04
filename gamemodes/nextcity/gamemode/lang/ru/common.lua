-- Общие строки интерфейса: ключи "common.<ключ>".
-- Формы множественного числа: one (1, 21), few (2-4, 22-24), many (0, 5-20), other (дроби).
return {
	yes = "Да",
	no = "Нет",
	ok = "ОК",
	cancel = "Отмена",
	close = "Закрыть",
	back = "Назад",
	["language.auto"] = "Язык игры ({language})",
	["language.changed"] = "Язык: {language}",
	["time.seconds"] = {
		one = "{count} секунда",
		few = "{count} секунды",
		many = "{count} секунд",
		other = "{count} секунды",
	},
	["time.minutes"] = {
		one = "{count} минута",
		few = "{count} минуты",
		many = "{count} минут",
		other = "{count} минуты",
	},
	["players.count"] = {
		one = "{count} игрок",
		few = "{count} игрока",
		many = "{count} игроков",
		other = "{count} игрока",
	},
}
