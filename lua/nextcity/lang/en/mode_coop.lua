-- Strings of the CO-OP mode: keys "mode_coop.<key>".
return {
	name = "CO-OP",
	intro = {
		one = "Clear the map: {count} enemy, lives of the team: {lives}",
		other = "Clear the map: {count} enemies, lives of the team: {lives}",
	},
	status = "Enemies: {count} · Lives: {lives}",
	life = "{who} fell, lives left: {lives}",
	out = "{who} fell, no lives left",
	["result.won"] = "The map is clear",
	["result.lost"] = "The mission failed",
	["reason.cleared"] = "No enemy is left",
	["reason.fallen"] = {
		one = "Everybody fell, {count} enemy was left",
		other = "Everybody fell, {count} enemies were left",
	},
	["reason.time"] = {
		one = "Time is up, {count} enemy was left",
		other = "Time is up, {count} enemies were left",
	},
	["reason.empty"] = "No enemies on the map: nc_npcs add or param perPlayer",
}
