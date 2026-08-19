OBJLoader = {}

OBJLoader.Type = {Single = 1, Multiple = 2, MultipleDepthSorted = 3}

OBJLoader.cachedRequests = {}
OBJLoader.adaptiveModels = setmetatable({}, {__mode = "k"})

class("MeshRequester", OBJLoader)

local keyframes = {
    {hour = 0.0, color = Color(50, 62, 85)},
    {hour = 4.0, color = Color(50, 62, 85)},
    {hour = 6.0, color = Color(115, 95, 80)},
    {hour = 7.0, color = Color(180, 145, 105)},
    {hour = 8.0, color = Color(185, 165, 135)},
    {hour = 12.0, color = Color(185, 175, 155)},
    {hour = 16.0, color = Color(180, 170, 150)},
    {hour = 18.0, color = Color(180, 145, 110)},
    {hour = 19.0, color = Color(120, 95, 80)},
    {hour = 20.0, color = Color(50, 62, 85)},
    {hour = 24.0, color = Color(50, 62, 85)}
}

function OBJLoader.GetAmbientColor()
    local time = Game:GetTime()

    local prevKf = keyframes[1]
    local nextKf = keyframes[#keyframes]

    for i = 1, #keyframes - 1 do
        if time >= keyframes[i].hour and time < keyframes[i + 1].hour then
            prevKf = keyframes[i]
            nextKf = keyframes[i + 1]
            break
        end
    end

    local range = nextKf.hour - prevKf.hour
    local ratio = (time - prevKf.hour) / range

    local r = math.lerp(prevKf.color.r, nextKf.color.r, ratio)
    local g = math.lerp(prevKf.color.g, nextKf.color.g, ratio)
    local b = math.lerp(prevKf.color.b, nextKf.color.b, ratio)

    return Color(r, g, b)
end

Events:Subscribe("PreTick", function()
    local ambientColor = OBJLoader.GetAmbientColor()
    for model, _ in pairs(OBJLoader.adaptiveModels) do
        model:SetColor(ambientColor)
    end
end)

local function IsMaterialTransparent(name, matData)
    if not matData then return false end
    if matData.opacity and matData.opacity < 1.0 then return true end
    if matData.hasOpacityMap then return true end
    return false
end

local function WrapSingleModel(model, name, isTransparent)
    local mt = {
        __index = function(t, key)
            if key == "DrawOpaque" then
                return function(self)
                    if not isTransparent then
                        model:Draw()
                    end
                end
            elseif key == "DrawTransparent" then
                return function(self)
                    if isTransparent then
                        model:Draw()
                    end
                end
            elseif key == "Draw" then
                return function(self)
                    model:Draw()
                end
            else
                local val = model[key]
                if type(val) == "function" then
                    return function(self, ...)
                        return val(model, ...)
                    end
                else
                    return val
                end
            end
        end
    }
    local wrapper = {}
    setmetatable(wrapper, mt)
    return wrapper
end

local function CreateModelGroup(models, meshTransparency)
    local opaque = {}
    local transparent = {}

    for name, m in pairs(models) do
        local isTransparent = meshTransparency[name]
        if isTransparent then
            transparent[name] = m
        else
            opaque[name] = m
        end
    end

    local mt = {
        __index = {
            Draw = function(t)
                for _, m in pairs(t.opaque) do
                    m:Draw()
                end
                for _, m in pairs(t.transparent) do
                    m:Draw()
                end
            end,
            DrawOpaque = function(t)
                for _, m in pairs(t.opaque) do
                    m:Draw()
                end
            end,
            DrawTransparent = function(t)
                for _, m in pairs(t.transparent) do
                    m:Draw()
                end
            end,
            Set2D = function(t, state)
                for _, m in pairs(t.opaque) do
                    m:Set2D(state)
                end
                for _, m in pairs(t.transparent) do
                    m:Set2D(state)
                end
            end,
            SetTopology = function(t, topo)
                for _, m in pairs(t.opaque) do
                    m:SetTopology(topo)
                end
                for _, m in pairs(t.transparent) do
                    m:SetTopology(topo)
                end
            end,
            SetTexture = function(t, tex)
                for _, m in pairs(t.opaque) do
                    m:SetTexture(tex)
                end
                for _, m in pairs(t.transparent) do
                    m:SetTexture(tex)
                end
            end,
            SetColor = function(t, col)
                for _, m in pairs(t.opaque) do
                    m:SetColor(col)
                end
                for _, m in pairs(t.transparent) do
                    m:SetColor(col)
                end
            end
        }
    }

    local group = {opaque = opaque, transparent = transparent}
    setmetatable(group, mt)
    return group
end

function OBJLoader.MeshRequester:__init(args, callback, callbackInstance)
    self.modelPath = args.path
    self.type = args.type or OBJLoader.Type.Single
    self.is2D = args.is2D or false
    self.adaptiveLighting = args.adaptiveLighting or false

    self.callbacks = {}
    self.models = {}
    self.depths = {}
    self.meshTransparency = {}
    self.modelCount = 0
    self.isFinished = false
    self.result = nil

    self:AddCallback(callback, callbackInstance)

    if not self.is2D and self.type == OBJLoader.Type.MultipleDepthSorted then
        error("[OBJLoader] Cannot be 3D and MultipleDepthSorted!")
    end

    self.tempModelData = {vertices = {}, uvs = {}, meshes = {}, colors = {}}

    Network:Send("OBJLoaderRequest", self.modelPath)

    self.startSub = Network:Subscribe("OBJLoaderStart", self, self.OnStart)
    self.vertSub = Network:Subscribe("OBJLoaderVertices", self, self.OnVertices)
    self.uvSub = Network:Subscribe("OBJLoaderUVs", self, self.OnUVs)
    self.triSub = Network:Subscribe("OBJLoaderTriangles", self, self.OnTriangles)
    self.completeSub = Network:Subscribe("OBJLoaderComplete", self, self.OnComplete)
end

function OBJLoader.MeshRequester:OnStart(args)
    if args.modelPath ~= self.modelPath then return end

    self.tempModelData.colors = args.colors
    for _, name in ipairs(args.meshNames) do
        self.tempModelData.meshes[name] = {triangleData = {}}
    end
end

function OBJLoader.MeshRequester:OnVertices(args)
    if args.modelPath ~= self.modelPath then return end

    local startIndex = args.startIndex
    for idx, vert in ipairs(args.vertices) do
        self.tempModelData.vertices[startIndex + idx - 1] = vert
    end
end

function OBJLoader.MeshRequester:OnUVs(args)
    if args.modelPath ~= self.modelPath then return end

    local startIndex = args.startIndex
    for idx, uv in ipairs(args.uvs) do
        self.tempModelData.uvs[startIndex + idx - 1] = uv
    end
end

function OBJLoader.MeshRequester:OnTriangles(args)
    if args.modelPath ~= self.modelPath then return end

    local startIndex = args.startIndex
    local mesh = self.tempModelData.meshes[args.meshName]

    if mesh then
        for idx, tri in ipairs(args.triangles) do
            mesh.triangleData[startIndex + idx - 1] = tri
        end
    end
end

function OBJLoader.MeshRequester:OnComplete(args)
    if args.modelPath ~= self.modelPath then return end

    Network:Unsubscribe(self.startSub)
    Network:Unsubscribe(self.vertSub)
    Network:Unsubscribe(self.uvSub)
    Network:Unsubscribe(self.triSub)
    Network:Unsubscribe(self.completeSub)

    local co = coroutine.create(function()
        self:ProcessModelData(self.tempModelData)
        self.tempModelData = nil
    end)

    local tickSub
    tickSub = Events:Subscribe("PreTick", function()
        if coroutine.status(co) == "dead" then
            Events:Unsubscribe(tickSub)
            return
        end

        local success, err = coroutine.resume(co)
        if not success then
            warn("[OBJLoader] Async load error: " .. tostring(err))
            Events:Unsubscribe(tickSub)
        end
    end)
end

function OBJLoader.MeshRequester:ProcessModelData(modelData)
    local modelVertices = modelData.vertices
    local modelColors = modelData.colors

    local meshType = self.type
    local is2D = self.is2D
    local multipleDepthSortedType = OBJLoader.Type.MultipleDepthSorted

    local fallbackColor = Color(255, 255, 255)

    local frameBudget = 500
    local processedInCurrentFrame = 0

    for modelName, mesh in pairs(modelData.meshes) do
        local vertices = {}
        local depthsBuffer = 0
        local vCount = 1
        local triangleDataList = mesh.triangleData
        local textureName = nil
        local meshDepth = 0

        for index = 1, #triangleDataList do
            local triangleData = triangleDataList[index]

            local matData = modelColors[triangleData[4]] or {color = fallbackColor, texture = nil, opacity = 1.0}

            local color = Color(matData.color.r, matData.color.g, matData.color.b)
            if matData.opacity and matData.opacity < 1.0 then
                color.a = math.floor(matData.opacity * 255)
            end

            local matTexture = matData.texture

            if not textureName and matTexture then
                textureName = matTexture
            end

            local p1 = triangleData[1]
            local p2 = triangleData[2]
            local p3 = triangleData[3]

            local vert1 = modelVertices[p1[1]]
            local vert2 = modelVertices[p2[1]]
            local vert3 = modelVertices[p3[1]]

            local uv1 = p1[2] and modelData.uvs[p1[2]]
            local uv2 = p2[2] and modelData.uvs[p2[2]]
            local uv3 = p3[2] and modelData.uvs[p3[2]]

            if is2D then
                vertices[vCount] = Vertex(Vector2(vert1.x, vert1.z), color)
                vertices[vCount + 1] = Vertex(Vector2(vert2.x, vert2.z), color)
                vertices[vCount + 2] = Vertex(Vector2(vert3.x, vert3.z), color)
                vCount = vCount + 3

                if meshType == multipleDepthSortedType then
                    depthsBuffer = depthsBuffer + vert1.y + vert2.y + vert3.y
                end
            else
                if matTexture and uv1 and uv2 and uv3 then
                    vertices[vCount] = Vertex(vert1, uv1)
                    vertices[vCount].color = color

                    vertices[vCount + 1] = Vertex(vert2, uv2)
                    vertices[vCount + 1].color = color

                    vertices[vCount + 2] = Vertex(vert3, uv3)
                    vertices[vCount + 2].color = color
                else
                    vertices[vCount] = Vertex(vert1, color)
                    vertices[vCount + 1] = Vertex(vert2, color)
                    vertices[vCount + 2] = Vertex(vert3, color)
                end
                vCount = vCount + 3
            end

            processedInCurrentFrame = processedInCurrentFrame + 2
            if processedInCurrentFrame >= frameBudget then
                processedInCurrentFrame = 0
                coroutine.yield()
            end
        end

        local model = Model.Create(vertices)
        model:SetTopology(Topology.TriangleList)
        model:Set2D(is2D)

        if textureName then
            local success, texture = pcall(function()
                return Image.Create(AssetLocation.Resource, textureName)
            end)

            if success and texture then
                model:SetTexture(texture)
            else
                warn("[OBJLoader] Texture failed to initialize: " .. tostring(textureName))
            end
        end

        local lastColorIndex = triangleDataList[1] and triangleDataList[1][4]
        local matData = lastColorIndex and modelColors[lastColorIndex]
        self.meshTransparency[modelName] = IsMaterialTransparent(modelName, matData)

        self.models[modelName] = model

        if meshType == multipleDepthSortedType then
            meshDepth = depthsBuffer / math.max(#vertices, 1)
            self.depths[modelName] = meshDepth
        end

        self.modelCount = self.modelCount + 1

        processedInCurrentFrame = 0
        coroutine.yield()
    end

    if meshType == multipleDepthSortedType then
        local buffer = {}

        for name, model in pairs(self.models) do
            table.insert(buffer, {model = model, depth = self.depths[name] or 0})
        end

        table.sort(buffer, function(a, b) return a.depth < b.depth end)

        self.models = {}

        for _, t in ipairs(buffer) do
            table.insert(self.models, t.model)
        end
    end

    local modelCount = 0
    local lastModel = nil
    local lastModelName = nil

    for name, m in pairs(self.models) do
        modelCount = modelCount + 1
        lastModel = m
        lastModelName = name
    end

    if meshType == OBJLoader.Type.Single then
        if modelCount == 1 then
            self.result = WrapSingleModel(lastModel, lastModelName, self.meshTransparency[lastModelName])
        else
            self.result = CreateModelGroup(self.models, self.meshTransparency)
        end
    else
        self.result = self.models
    end

    if self.adaptiveLighting then
        OBJLoader.adaptiveModels[self.result] = true
    end

    for index, callback in ipairs(self.callbacks) do
        self:ForceCallback(callback.func, callback.instance)
    end

    self.isFinished = true
end

function OBJLoader.MeshRequester:AddCallback(func, instance)
    table.insert(self.callbacks, {func = func, instance = instance})
end

function OBJLoader.MeshRequester:ForceCallback(func, instance)
    if instance then
        func(instance, self.result, self.modelPath)
    else
        func(self.result, self.modelPath)
    end
end

function OBJLoader.Request(args, extra1, extra2)
    if extra1 == nil or type(args) ~= "table" or type(args.path) ~= "string" then
        error("[OBJLoader] Error: bad parameters")
    end

    local onLoadCallback = nil
    local onLoadCallbackInstance = nil

    if extra2 then
        onLoadCallback = extra2
        onLoadCallbackInstance = extra1
    else
        onLoadCallback = extra1
    end

    local cachedRequest = OBJLoader.cachedRequests[args.path]

    if cachedRequest then
        if args.adaptiveLighting then
            cachedRequest.adaptiveLighting = true
            if cachedRequest.result then
                OBJLoader.adaptiveModels[cachedRequest.result] = true
            end
        end

        if cachedRequest.isFinished then
            cachedRequest:ForceCallback(onLoadCallback, onLoadCallbackInstance)
        else
            cachedRequest:AddCallback(onLoadCallback, onLoadCallbackInstance)
        end
    else
        OBJLoader.cachedRequests[args.path] = OBJLoader.MeshRequester(args, onLoadCallback, onLoadCallbackInstance)
    end
end