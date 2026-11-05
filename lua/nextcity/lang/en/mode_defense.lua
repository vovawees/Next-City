-- Strings of the Defense mode: keys "mode_defense.<key>".
return {
	name = "Defense",
	intro = {
		one = "Hold out against {count} wave of enemies",
		other = "Hold out against {count} waves of enemies",
	},
	["status.pause"] = "Wave {wave} of {waves} in {time}",
	["status.wave"] = {
		one = "Wave {wave} of {waves}: {count} enemy left",
		other = "Wave {wave} of {waves}: {count} enemies left",
	},
	wave = "Wave {wave} of {waves} is coming!",
	beaten = "Wave {wave} of {waves} is beaten: the fallen are back",
	["result.won"] = "The defense held",
	["result.lost"] = "The defense fell",
	["reason.held"] = {
		one = "{count} wave beaten",
		other = "All {count} waves beaten",
	},
	["reason.fallen"] = "Everybody fell on wave {wave} of {waves}",
	["reason.nowhere"] = "The enemies have nowhere to appear: nc_npcs add",
}
