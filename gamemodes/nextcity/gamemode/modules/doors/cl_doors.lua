-- Doors, client part: the door in front of the local player and the requests of its menu.
--
--   doors:Aimed()                   -> the door in front within config.range, or nil
--   doors:Ask(op, door, arg)        -> asks the server: buy, sell, lock, unlock, add, remove
--                                      (arg: the player), title (arg: the text)

local M = NC.Module("doors")

local IsValid = IsValid

function M:Aimed()
	local me = LocalPlayer()
	if not IsValid(me) then
		return nil
	end
	local eye = me:GetShootPos()
	local tr = util.TraceLine({ start = eye, endpos = eye + me:GetAimVector() * self.ctx.config.range,
		filter = me, mask = MASK_SHOT })
	local ent = tr ~= nil and tr.Entity or nil
	return self:IsDoor(ent) and ent or nil
end

function M:Ask(op, door, arg)
	if not self:IsDoor(door) then
		return
	end
	local data = { op = op, door = door }
	if op == "title" then
		data.title = tostring(arg or "")
	elseif arg ~= nil then
		data.target = arg
	end
	self.ctx.net:SendToServer("door", data)
end
