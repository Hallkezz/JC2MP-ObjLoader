---------------
--By Hallkezz--
---------------

class 'ModelSpawner'

function ModelSpawner:__init()
    self.scale = 0.025
    self.offset = Vector3(0, 0.05, 0)

    self.toggleKey = 85 -- U

    self:LoadModel()

    Events:Subscribe("KeyUp", self, self.KeyUp)

    Network:Subscribe("SpawnModel", self, self.SpawnModel)
    Network:Subscribe("RemoveModel", self, self.RemoveModel)
end

function ModelSpawner:LoadModel()
    OBJLoader.Request(
        {
            path = "models/example",
            is2D = false,
            adaptiveLighting = true
        },

        function(model)
            print("Model successfully loaded!")
            self.model = model
        end
    )
end

function ModelSpawner:SpawnModel(player)
    self.position = player:GetPosition()
    self.angle = player:GetAngle()

    self.GameRenderOpaqueEvent = Events:Subscribe("GameRenderOpaque", self, self.GameRenderOpaque)
    self.GameRenderEvent = Events:Subscribe("GameRender", self, self.GameRender)

    self.active = true

    Chat:Print("Model spawned", Color(0, 255, 0))
end

function ModelSpawner:RemoveModel()
    Events:Unsubscribe(self.GameRenderOpaqueEvent)
    Events:Unsubscribe(self.GameRenderEvent)

    self.GameRenderOpaqueEvent = nil
    self.GameRenderEvent = nil

    self.position = nil
    self.angle = nil

    self.active = nil

    Chat:Print("Model removed", Color(255, 0, 0))
end

function ModelSpawner:KeyUp(args)
    if args.key == self.toggleKey then
        if not self.active then
            Network:Send("SpawnModel", LocalPlayer)
        else
            Network:Send("RemoveModel")
        end
    end
end

function ModelSpawner:GameRenderOpaque()
    if not (self.model or self.position or self.angle) then return end

    local pos = self.position + self.angle * self.offset
    local angle = self.angle * Angle(math.pi, 0, 0)

    local transform = Transform3()
    transform:Translate(pos)
    transform:Rotate(angle)
    transform:Scale(self.scale)

    Render:SetTransform(transform)
    self.model:DrawOpaque()
end

function ModelSpawner:GameRender()
    if not (self.model or self.position or self.angle) then return end

    local pos = self.position + self.angle * self.offset
    local angle = self.angle * Angle(math.pi, 0, 0)

    local transform = Transform3()
    transform:Translate(pos)
    transform:Rotate(angle)
    transform:Scale(self.scale)

    Render:SetTransform(transform)
    self.model:DrawTransparent()
end

local modelSpawner = ModelSpawner()