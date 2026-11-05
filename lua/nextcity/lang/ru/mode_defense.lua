-- Строки режима «Оборона»: ключи "mode_defense.<ключ>".
return {
	name = "Оборона",
	intro = {
		one = "Продержитесь {count} волну врагов",
		few = "Продержитесь {count} волны врагов",
		many = "Продержитесь {count} волн врагов",
		other = "Продержитесь {count} волны врагов",
	},
	["status.pause"] = "Волна {wave} из {waves} через {time}",
	["status.wave"] = {
		one = "Волна {wave} из {waves}: остался {count} враг",
		few = "Волна {wave} из {waves}: осталось {count} врага",
		many = "Волна {wave} из {waves}: осталось {count} врагов",
		other = "Волна {wave} из {waves}: осталось {count} врага",
	},
	wave = "Идёт волна {wave} из {waves}!",
	beaten = "Волна {wave} из {waves} отбита: павшие вернулись",
	["result.won"] = "Оборона выстояла",
	["result.lost"] = "Оборона пала",
	["reason.held"] = {
		one = "Отбита {count} волна",
		few = "Отбиты все {count} волны",
		many = "Отбиты все {count} волн",
		other = "Отбиты все {count} волны",
	},
	["reason.fallen"] = "Все пали на волне {wave} из {waves}",
	["reason.nowhere"] = "Врагам негде появиться: nc_npcs add",
}
