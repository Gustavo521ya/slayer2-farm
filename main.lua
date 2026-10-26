-- main.lua
-- Roblox Studio LocalScript para um jogo próprio/ambiente autorizado.
-- Recursos: painel, diagnóstico de NPCs, seleção de alvo, movimento por TweenService,
-- cancelamento do movimento e invisibilidade apenas local do próprio personagem.
-- Coloque como LocalScript em StarterPlayer > StarterPlayerScripts.

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local Workspace = game:GetService("Workspace")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")

local oldGui = playerGui:FindFirstChild("SlayersHelperPanel")
if oldGui then
    oldGui:Destroy()
end

local currentTween = nil
local selectedTarget = nil
local invisible = false
local originalTransparency = {}

local function getCharacter()
    return player.Character or player.CharacterAdded:Wait()
end

local function getRoot(model)
    return model and (model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart)
end

local function isNpc(model)
    if not model or not model:IsA("Model") then
        return false
    end
    if player.Character and model == player.Character then
        return false
    end
    local humanoid = model:FindFirstChildOfClass("Humanoid")
    local root = getRoot(model)
    return humanoid ~= nil and root ~= nil and humanoid.Health > 0
end

local function collectNpcs()
    local list = {}
    for _, obj in ipairs(Workspace:GetDescendants()) do
        if obj:IsA("Model") and isNpc(obj) then
            table.insert(list, obj)
        end
    end
    table.sort(list, function(a, b)
        return a:GetFullName() < b:GetFullName()
    end)
    return list
end

local gui = Instance.new("ScreenGui")
gui.Name = "SlayersHelperPanel"
gui.ResetOnSpawn = false
gui.ZIndexBehavior = Enum.ZIndexBehavior.Sibling
gui.Parent = playerGui

local main = Instance.new("Frame")
main.Name = "Main"
main.Size = UDim2.fromOffset(310, 390)
main.Position = UDim2.new(0, 20, 0.5, -195)
main.BackgroundColor3 = Color3.fromRGB(24, 25, 32)
main.BorderSizePixel = 0
main.Parent = gui

local corner = Instance.new("UICorner")
corner.CornerRadius = UDim.new(0, 10)
corner.Parent = main

local stroke = Instance.new("UIStroke")
stroke.Color = Color3.fromRGB(75, 82, 105)
stroke.Thickness = 1
stroke.Parent = main

local title = Instance.new("TextLabel")
title.Size = UDim2.new(1, -20, 0, 34)
title.Position = UDim2.fromOffset(10, 5)
title.BackgroundTransparency = 1
title.Text = "Slayers Helper • Studio"
title.TextColor3 = Color3.fromRGB(240, 242, 255)
title.Font = Enum.Font.GothamBold
title.TextSize = 15
title.TextXAlignment = Enum.TextXAlignment.Left
title.Parent = main

local status = Instance.new("TextLabel")
status.Size = UDim2.new(1, -20, 0, 38)
status.Position = UDim2.fromOffset(10, 39)
status.BackgroundColor3 = Color3.fromRGB(35, 38, 48)
status.Text = "Pronto. Atualize a lista de NPCs."
status.TextColor3 = Color3.fromRGB(205, 210, 225)
status.Font = Enum.Font.Gotham
status.TextSize = 11
status.TextWrapped = true
status.Parent = main
Instance.new("UICorner", status).CornerRadius = UDim.new(0, 6)

local function makeButton(text, position, size)
    local button = Instance.new("TextButton")
    button.Size = size
    button.Position = position
    button.BackgroundColor3 = Color3.fromRGB(57, 66, 91)
    button.TextColor3 = Color3.fromRGB(255, 255, 255)
    button.Font = Enum.Font.GothamSemibold
    button.TextSize = 12
    button.Text = text
    button.AutoButtonColor = true
    button.Parent = main
    Instance.new("UICorner", button).CornerRadius = UDim.new(0, 6)
    return button
end

local refreshButton = makeButton("Atualizar NPCs", UDim2.fromOffset(10, 84), UDim2.new(0.5, -15, 0, 30))
local cancelButton = makeButton("Cancelar movimento", UDim2.new(0.5, 5, 0, 84), UDim2.new(0.5, -15, 0, 30))
local moveButton = makeButton("Mover até alvo selecionado", UDim2.fromOffset(10, 120), UDim2.new(1, -20, 0, 30))
local invisButton = makeButton("Invisibilidade local: OFF", UDim2.fromOffset(10, 156), UDim2.new(1, -20, 0, 30))
local diagnosticButton = makeButton("Diagnóstico", UDim2.fromOffset(10, 192), UDim2.new(1, -20, 0, 30))

local listFrame = Instance.new("ScrollingFrame")
listFrame.Name = "NpcList"
listFrame.Size = UDim2.new(1, -20, 0, 115)
listFrame.Position = UDim2.fromOffset(10, 230)
listFrame.BackgroundColor3 = Color3.fromRGB(31, 33, 42)
listFrame.BorderSizePixel = 0
listFrame.ScrollBarThickness = 5
listFrame.CanvasSize = UDim2.fromOffset(0, 0)
listFrame.Parent = main
Instance.new("UICorner", listFrame).CornerRadius = UDim.new(0, 6)

local listLayout = Instance.new("UIListLayout")
listLayout.Padding = UDim.new(0, 4)
listLayout.SortOrder = Enum.SortOrder.LayoutOrder
listLayout.Parent = listFrame

local footer = Instance.new("TextLabel")
footer.Size = UDim2.new(1, -20, 0, 28)
footer.Position = UDim2.fromOffset(10, 350)
footer.BackgroundTransparency = 1
footer.Text = "Selecione um NPC na lista antes de mover."
footer.TextColor3 = Color3.fromRGB(160, 168, 190)
footer.Font = Enum.Font.Gotham
footer.TextSize = 10
footer.TextWrapped = true
footer.Parent = main

-- Arrastar o painel com o mouse/toque.
do
    local dragging = false
    local dragInput
    local dragStart
    local startPosition

    title.InputBegan:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseButton1
            or input.UserInputType == Enum.UserInputType.Touch then
            dragging = true
            dragStart = input.Position
            startPosition = main.Position
            input.Changed:Connect(function()
                if input.UserInputState == Enum.UserInputState.End then
                    dragging = false
                end
            end)
        end
    end)

    title.InputChanged:Connect(function(input)
        if input.UserInputType == Enum.UserInputType.MouseMovement
            or input.UserInputType == Enum.UserInputType.Touch then
            dragInput = input
        end
    end)

    game:GetService("UserInputService").InputChanged:Connect(function(input)
        if dragging and input == dragInput then
            local delta = input.Position - dragStart
            main.Position = UDim2.new(
                startPosition.X.Scale, startPosition.X.Offset + delta.X,
                startPosition.Y.Scale, startPosition.Y.Offset + delta.Y
            )
        end
    end)
end

local function setStatus(message)
    status.Text = message
end

local function clearNpcButtons()
    for _, child in ipairs(listFrame:GetChildren()) do
        if child:IsA("TextButton") then
            child:Destroy()
        end
    end
end

local function refreshNpcList()
    clearNpcButtons()
    selectedTarget = nil
    local npcs = collectNpcs()

    for index, npc in ipairs(npcs) do
        local button = Instance.new("TextButton")
        button.Name = "Npc_" .. index
        button.Size = UDim2.new(1, -8, 0, 25)
        button.BackgroundColor3 = Color3.fromRGB(47, 51, 65)
        button.TextColor3 = Color3.fromRGB(225, 230, 245)
        button.Font = Enum.Font.Gotham
        button.TextSize = 11
        button.TextXAlignment = Enum.TextXAlignment.Left
        button.TextTruncate = Enum.TextTruncate.AtEnd
        button.Text = "  " .. npc.Name
        button.LayoutOrder = index
        button.Parent = listFrame
        Instance.new("UICorner", button).CornerRadius = UDim.new(0, 4)

        button.Activated:Connect(function()
            selectedTarget = npc
            for _, other in ipairs(listFrame:GetChildren()) do
                if other:IsA("TextButton") then
                    other.BackgroundColor3 = Color3.fromRGB(47, 51, 65)
                end
            end
            button.BackgroundColor3 = Color3.fromRGB(79, 105, 151)
            setStatus("Alvo selecionado: " .. npc.Name)
        end)
    end

    listFrame.CanvasSize = UDim2.fromOffset(0, #npcs * 29 + 4)
    setStatus("NPCs encontrados: " .. #npcs .. ". Selecione um alvo.")
end

refreshButton.Activated:Connect(refreshNpcList)

cancelButton.Activated:Connect(function()
    if currentTween then
        currentTween:Cancel()
        currentTween = nil
        setStatus("Movimento cancelado.")
    else
        setStatus("Não há movimento ativo.")
    end
end)

moveButton.Activated:Connect(function()
    if not selectedTarget or not selectedTarget.Parent or not isNpc(selectedTarget) then
        setStatus("Alvo inválido. Atualize a lista e selecione outro NPC.")
        return
    end

    local character = getCharacter()
    local root = getRoot(character)
    local targetRoot = getRoot(selectedTarget)
    if not root or not targetRoot then
        setStatus("Não foi possível encontrar a raiz do personagem/alvo.")
        return
    end

    if currentTween then
        currentTween:Cancel()
        currentTween = nil
    end

    local destination = targetRoot.CFrame * CFrame.new(0, 0, 4)
    local distance = (root.Position - destination.Position).Magnitude
    local duration = math.clamp(distance / 50, 0.25, 8)

    currentTween = TweenService:Create(
        root,
        TweenInfo.new(duration, Enum.EasingStyle.Linear, Enum.EasingDirection.Out),
        { CFrame = destination }
    )

    currentTween.Completed:Connect(function(playbackState)
        if playbackState == Enum.PlaybackState.Completed then
            setStatus("Movimento concluído até: " .. selectedTarget.Name)
        end
        currentTween = nil
    end)

    currentTween:Play()
    setStatus("Movendo até " .. selectedTarget.Name .. "...")
end)

local function setLocalInvisibility(enabled)
    local character = getCharacter()
    if enabled then
        for _, obj in ipairs(character:GetDescendants()) do
            if obj:IsA("BasePart") then
                if originalTransparency[obj] == nil then
                    originalTransparency[obj] = obj.LocalTransparencyModifier
                end
                obj.LocalTransparencyModifier = 1
            elseif obj:IsA("Decal") or obj:IsA("Texture") then
                if originalTransparency[obj] == nil then
                    originalTransparency[obj] = obj.Transparency
                end
                obj.Transparency = 1
            end
        end
    else
        for obj, value in pairs(originalTransparency) do
            if obj and obj.Parent then
                if obj:IsA("BasePart") then
                    obj.LocalTransparencyModifier = value
                elseif obj:IsA("Decal") or obj:IsA("Texture") then
                    obj.Transparency = value
                end
            end
        end
        table.clear(originalTransparency)
    end
end

invisButton.Activated:Connect(function()
    invisible = not invisible
    setLocalInvisibility(invisible)
    invisButton.Text = "Invisibilidade local: " .. (invisible and "ON" or "OFF")
    setStatus(invisible
        and "Aparência ocultada apenas neste cliente; não é invisibilidade no servidor."
        or "Transparência local restaurada.")
end)

diagnosticButton.Activated:Connect(function()
    local npcs = collectNpcs()
    local folders = 0
    for _, obj in ipairs(Workspace:GetChildren()) do
        if obj:IsA("Folder") or obj:IsA("Model") then
            folders += 1
        end
    end

    local selectedName = selectedTarget and selectedTarget.Parent and selectedTarget.Name or "nenhum"
    setStatus(("Diagnóstico: %d modelos com Humanoid vivos; %d pastas/modelos no Workspace; alvo: %s.")
        :format(#npcs, folders, selectedName))
end)

player.CharacterAdded:Connect(function()
    if invisible then
        task.wait(0.5)
        setLocalInvisibility(true)
    end
end)

refreshNpcList()
