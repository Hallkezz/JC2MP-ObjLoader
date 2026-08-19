---------------
--By Hallkezz--
---------------

class 'ModelSpawner'

function ModelSpawner:__init()
    Events:Subscribe("ClientModuleLoad", self, self.ClientModuleLoad)
    Events:Subscribe("PlayerQuit", self, self.PlayerQuit)

    Network:Subscribe("SpawnModel", self, self.SpawnModel)
    Network:Subscribe("RemoveModel", self, self.RemoveModel)
end

function ModelSpawner:ClientModuleLoad(args)
    if IsValid(self.activePlayer) then
        Network:Send(args.player, "SpawnModel", self.activePlayer)
    end
end

function ModelSpawner:PlayerQuit(args)
    if args.player == self.activePlayer then
        self:RemoveModel()
    end
end

function ModelSpawner:SpawnModel(player)
    Network:Broadcast("SpawnModel", player)
    self.activePlayer = player
end

function ModelSpawner:RemoveModel()
    Network:Broadcast("RemoveModel")
    self.activePlayer = nil
end

local modelSpawner = ModelSpawner()