OBJLoader = {}
OBJLoader.cache = {}

local function TrimComments(line)
    local hashIndex = string.find(line, "#")

    if hashIndex then
        return string.sub(line, 1, hashIndex - 1)
    end

    return line
end

local function ConvertWord(word)
    if not word or word == "" then return nil end

    local tokens = word:split("/")
    local vertex = tonumber(tokens[1])
    local uv = tokens[2] and tokens[2] ~= "" and tonumber(tokens[2]) or nil
    local normal = tokens[3] and tokens[3] ~= "" and tonumber(tokens[3]) or nil

    return vertex, uv, normal
end

function OBJLoader.Load(path)
    if path:sub(-4) == ".obj" then
        path = path:sub(1, -5)
    end

    local cachedModel = OBJLoader.cache[path]
    if cachedModel then
        return cachedModel
    end

    local model = {vertices = {}, uvs = {}, meshes = {}, colors = {}}

    local file, err = io.open(path .. ".mtl", "r")
    local colorMap = {}

    if err then
        table.insert(model.colors, {color = Color(255, 0, 255), texture = nil, opacity = 1.0, hasOpacityMap = false})
    else
        local colorCount = 0

        for line in file:lines() do
            line = TrimComments(line)
            line = line:match("^%s*(.-)%s*$") or line

            if #line > 0 then
                local tokens = line:split(" ")
                local key = tokens[1]

                if key == "newmtl" then
                    colorCount = colorCount + 1
                    local mtlName = line:sub(#key + 2):match("^%s*(.-)%s*$")
                    colorMap[mtlName] = colorCount
                    model.colors[colorCount] = {color = Color(255, 255, 255), texture = nil, opacity = 1.0, hasOpacityMap = false}
                elseif key == "Kd" then
                    model.colors[colorCount].color = Color(tonumber(tokens[2]) * 255, tonumber(tokens[3]) * 255, tonumber(tokens[4]) * 255)
                elseif key == "d" then
                    model.colors[colorCount].opacity = tonumber(tokens[2])
                elseif key == "Tr" then
                    model.colors[colorCount].opacity = 1.0 - tonumber(tokens[2])
                elseif key == "map_d" then
                    model.colors[colorCount].hasOpacityMap = true
                elseif key == "map_Kd" then
                    local texturePath = line:sub(#key + 2):match("^%s*(.-)%s*$")
                    local filename = texturePath:match("([^/\\]+)$") or texturePath
                    model.colors[colorCount].texture = filename
                end
            end
        end
        file:close()
    end

    file, err = io.open(path .. ".obj", "r")
    if err then
        return nil, err
    end

    local meshes = {}
    local currentMaterialName = "Default"
    local currentColorIndex = 1

    meshes[currentMaterialName] = {triangleData = {}}

    for line in file:lines() do
        line = TrimComments(line)
        line = line:match("^%s*(.-)%s*$") or line

        if #line > 0 then
            local tokens = line:split(" ")
            local key = tokens[1]

            if key == "v" then
                local vertex = Vector3(tonumber(tokens[2]), tonumber(tokens[3]), tonumber(tokens[4]))
                table.insert(model.vertices, vertex)
            elseif key == "vt" then
                local u = tonumber(tokens[2])
                local v = tonumber(tokens[3])
                table.insert(model.uvs, Vector2(u, 1 - v))
            elseif key == "usemtl" then
                local mtlName = line:sub(#key + 2):match("^%s*(.-)%s*$")
                currentColorIndex = colorMap[mtlName] or 1
                currentMaterialName = mtlName

                if not meshes[currentMaterialName] then
                    meshes[currentMaterialName] = {triangleData = {}}
                end
            elseif key == "f" then
                local mesh = meshes[currentMaterialName]
                local v1, uv1 = ConvertWord(tokens[2])
                local v2, uv2 = ConvertWord(tokens[3])
                local v3, uv3 = ConvertWord(tokens[4])

                if v1 and v2 and v3 then
                    table.insert(mesh.triangleData, {{v1, uv1}, {v2, uv2}, {v3, uv3}, currentColorIndex})
                end

                if tokens[5] then
                    local v4, uv4 = ConvertWord(tokens[5])

                    if v4 then
                        table.insert(mesh.triangleData, {{v1, uv1}, {v3, uv3}, {v4, uv4}, currentColorIndex})
                    end
                end
            end
        end
    end

    for name, mesh in pairs(meshes) do
        if #mesh.triangleData > 0 then
            model.meshes[name] = mesh
        end
    end

    file:close()
    OBJLoader.cache[path] = model

    return model
end

function OBJLoader.Request(modelPath, player)
    if type(modelPath) ~= "string" then return end

    local model, err = OBJLoader.Load(modelPath)

    if not model then
        warn("[OBJLoader] Could not load " .. modelPath .. ": " .. tostring(err))
        return
    end

    local meshNames = {}

    for k, v in pairs(model.meshes) do
        table.insert(meshNames, k)
    end

    Network:Send(player, "OBJLoaderStart", {modelPath = modelPath, colors = model.colors, meshNames = meshNames})

    local chunkSize = 1500
    local totalVertices = #model.vertices

    for i = 1, totalVertices, chunkSize do
        local chunk = {}

        for j = i, math.min(i + chunkSize - 1, totalVertices) do
            table.insert(chunk, model.vertices[j])
        end

        Network:Send(player, "OBJLoaderVertices", {modelPath = modelPath, startIndex = i, vertices = chunk})
    end

    local totalUVs = #model.uvs

    for i = 1, totalUVs, chunkSize do
        local chunk = {}

        for j = i, math.min(i + chunkSize - 1, totalUVs) do
            table.insert(chunk, model.uvs[j])
        end

        Network:Send(player, "OBJLoaderUVs", {modelPath = modelPath, startIndex = i, uvs = chunk})
    end

    for meshName, mesh in pairs(model.meshes) do
        local triangles = mesh.triangleData
        local totalTriangles = #triangles
        local triChunkSize = 1000

        for i = 1, totalTriangles, triChunkSize do
            local chunk = {}

            for j = i, math.min(i + triChunkSize - 1, totalTriangles) do
                table.insert(chunk, triangles[j])
            end

            Network:Send(player, "OBJLoaderTriangles", {modelPath = modelPath, meshName = meshName, startIndex = i, triangles = chunk})
        end
    end

    Network:Send(player, "OBJLoaderComplete", {modelPath = modelPath})
end

Network:Subscribe("OBJLoaderRequest", OBJLoader.Request)