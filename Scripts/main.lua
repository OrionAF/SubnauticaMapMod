local UEHelpers = require("UEHelpers")
local Config = require("config")

local MOD_NAME = "SubnauticaMapMod"
local VISIBLE = 3 -- ESlateVisibility::HitTestInvisible
local HIDDEN = 2  -- ESlateVisibility::Hidden

local mapVisible = Config.ShowMinimapAtStartup ~= false
local largeMapOpen = false
local textureLoadAttempted = false
local pixelLoadAttempted = false
local arrowLoadAttempted = false
local attachAttemptLogged = false
local overlayAttachedLogged = false
local updateErrorLogged = false
local openToggleLocked = false
local hideToggleLocked = false
local calibrationLogged = false
local sampleQueued = false
local overlayGeneration = 0
local frameSample = {}
local drawState = {}
local mapPoint = {}
local cachedScreenW = 1920
local cachedScreenH = 1080
local viewportDirty = true
local viewportPollCountdown = 0

local renderingLibrary = CreateInvalidObject()
local widgetLayoutLibrary = CreateInvalidObject()
local mapTexture = CreateInvalidObject()
local pixelTexture = CreateInvalidObject()
local arrowTexture = CreateInvalidObject()

local overlay = {
    hudScreen = CreateInvalidObject(),
    root = CreateInvalidObject(),
    canvas = CreateInvalidObject(),
    canvasSlot = nil,
    dim = CreateInvalidObject(),
    dimSlot = nil,
    map = CreateInvalidObject(),
    mapSlot = nil,
    borderTop = CreateInvalidObject(),
    borderTopSlot = nil,
    borderRight = CreateInvalidObject(),
    borderRightSlot = nil,
    borderBottom = CreateInvalidObject(),
    borderBottomSlot = nil,
    borderLeft = CreateInvalidObject(),
    borderLeftSlot = nil,
    marker = CreateInvalidObject(),
    markerSlot = nil,
    mapTextureApplied = false,
    markerTextureApplied = false,
    lastCanvasVisible = nil,
    lastDimVisible = nil,
    lastMarkerVisible = nil,
    lastMarkerXKey = nil,
    lastMarkerYKey = nil,
    lastMarkerAngleKey = nil,
    lastMarkerSize = nil,
    lastHeadingAngleKey = nil,
}

local widgetClasses = {}
local runtimeBounds = nil
local configuredBounds = {
    MinX = Config.Map.WorldMinX,
    MaxX = Config.Map.WorldMaxX,
    MinY = Config.Map.WorldMinY,
    MaxY = Config.Map.WorldMaxY,
}
local mapGenieProjection = nil

local function log(message)
    print(string.format("[%s] %s\n", MOD_NAME, message))
end

local function isValid(object)
    return object and object.IsValid and object:IsValid()
end

local scratchVec2 = { X = 0.0, Y = 0.0 }
local function vec2(x, y)
    scratchVec2.X = x
    scratchVec2.Y = y
    return scratchVec2
end

local function color(value, fallbackAlpha)
    value = value or {}
    return {
        R = value.R or 1.0,
        G = value.G or 1.0,
        B = value.B or 1.0,
        A = value.A or fallbackAlpha or 1.0,
    }
end

local COLOR_BLACK = { R = 0.0, G = 0.0, B = 0.0, A = 0.45 }
local COLOR_WHITE = { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }
local COLOR_BORDER = { R = 0.0, G = 0.8, B = 1.0, A = 0.85 }
local COLOR_MARKER = color((Config.Marker or {}).Color, 1.0)

local lastWorldX = nil
local lastWorldY = nil
local lastForwardX = nil
local lastForwardY = nil

local cachedPawn = CreateInvalidObject()
local pawnCheckCountdown = 0
local PAWN_CHECK_INTERVAL = 10

local function clamp(value, minValue, maxValue)
    if value < minValue then return minValue end
    if value > maxValue then return maxValue end
    return value
end

local function quantize(value, step)
    step = step or 1
    if step <= 0 then return value end
    return math.floor((value / step) + 0.5)
end

local function safeCall(label, fn)
    local ok, result = pcall(fn)
    if not ok then
        log(label .. " failed: " .. tostring(result))
        return nil
    end
    return result
end

local function resetOverlayCaches()
    overlay.lastLayoutLarge = nil
    overlay.lastLayoutScreenW = nil
    overlay.lastLayoutScreenH = nil
    overlay.lastLayoutXKey = nil
    overlay.lastLayoutYKey = nil
    overlay.lastLayoutWidthKey = nil
    overlay.lastLayoutHeightKey = nil
    overlay.lastLayoutMapAlpha = nil
    overlay.lastLayoutBackgroundAlpha = nil
    overlay.lastLayoutBorderThickness = nil
    overlay.lastLayoutDimVisible = nil
    overlay.lastCanvasVisible = nil
    overlay.lastDimVisible = nil
    overlay.lastMarkerVisible = nil
    overlay.lastMarkerXKey = nil
    overlay.lastMarkerYKey = nil
    overlay.lastMarkerAngleKey = nil
    overlay.lastMarkerSize = nil
    overlay.lastHeadingAngleKey = nil
end

local function clearOverlayWidgetRefs(clearOwner)
    if clearOwner then
        overlay.hudScreen = CreateInvalidObject()
        overlay.root = CreateInvalidObject()
    end

    overlay.canvas = CreateInvalidObject()
    overlay.canvasSlot = nil
    overlay.dim = CreateInvalidObject()
    overlay.dimSlot = nil
    overlay.map = CreateInvalidObject()
    overlay.mapSlot = nil
    overlay.borderTop = CreateInvalidObject()
    overlay.borderTopSlot = nil
    overlay.borderRight = CreateInvalidObject()
    overlay.borderRightSlot = nil
    overlay.borderBottom = CreateInvalidObject()
    overlay.borderBottomSlot = nil
    overlay.borderLeft = CreateInvalidObject()
    overlay.borderLeftSlot = nil
    overlay.marker = CreateInvalidObject()
    overlay.markerSlot = nil
    overlay.mapTextureApplied = false
    overlay.markerTextureApplied = false
    resetOverlayCaches()
end

local function detachOverlay(clearOwner)
    if overlay.canvas and overlay.canvas:IsValid() then
        safeCall("Remove overlay canvas", function()
            overlay.canvas:RemoveFromParent()
        end)
    end

    clearOverlayWidgetRefs(clearOwner)
end

local function sameObject(a, b)
    return a and b and a:IsValid() and b:IsValid() and a:GetAddress() == b:GetAddress()
end

local function lockKeyForDebounce(unlock)
    ExecuteWithDelay(Config.KeyDebounceMs or 250, unlock)
end

local function isAbsolutePath(path)
    return path:match("^%a:[/\\]") ~= nil or path:match("^[/\\][/\\]") ~= nil
end

local function getAssetPath(fileName)
    if isAbsolutePath(fileName) then return fileName end

    local directories = IterateGameDirectories()
    local win64 = directories.Game.Binaries.Win64.__absolute_path
    return win64 .. "\\ue4ss\\Mods\\" .. MOD_NAME .. "\\Assets\\" .. fileName
end

local function fileExists(path)
    local file = io.open(path, "rb")
    if file then
        file:close()
        return true
    end
    return false
end

local function findDefaultObject(path)
    local object = StaticFindObject(path)
    if object and object:IsValid() then return object end
    return CreateInvalidObject()
end

local function getRenderingLibrary()
    if renderingLibrary:IsValid() then return renderingLibrary end
    renderingLibrary = findDefaultObject("/Script/Engine.Default__KismetRenderingLibrary")
    return renderingLibrary
end

local function getWidgetLayoutLibrary()
    if widgetLayoutLibrary:IsValid() then return widgetLayoutLibrary end
    widgetLayoutLibrary = findDefaultObject("/Script/UMG.Default__WidgetLayoutLibrary")
    return widgetLayoutLibrary
end

local function loadTexture(fileName, attemptedFlagName)
    local target = arrowTexture
    if attemptedFlagName == "map" then
        target = mapTexture
    elseif attemptedFlagName == "pixel" then
        target = pixelTexture
    end
    if target:IsValid() then return target end

    if attemptedFlagName == "map" and textureLoadAttempted then return target end
    if attemptedFlagName == "pixel" and pixelLoadAttempted then return target end
    if attemptedFlagName == "arrow" and arrowLoadAttempted then return target end

    local world = UEHelpers.GetWorld()
    local renderer = getRenderingLibrary()
    if not world:IsValid() or not renderer:IsValid() then return target end

    local path = getAssetPath(fileName)
    if not fileExists(path) then
        log("Texture not found: " .. path)
        if attemptedFlagName == "map" then
            textureLoadAttempted = true
        elseif attemptedFlagName == "pixel" then
            pixelLoadAttempted = true
        else
            arrowLoadAttempted = true
        end
        return target
    end

    if attemptedFlagName == "map" then
        textureLoadAttempted = true
    elseif attemptedFlagName == "pixel" then
        pixelLoadAttempted = true
    else
        arrowLoadAttempted = true
    end

    local texture = safeCall("ImportFileAsTexture2D(" .. fileName .. ")", function()
        return renderer:ImportFileAsTexture2D(world, path)
    end)

    if texture and texture:IsValid() then
        if attemptedFlagName == "map" then
            mapTexture = texture
        elseif attemptedFlagName == "pixel" then
            pixelTexture = texture
        else
            arrowTexture = texture
        end
        log("Texture loaded: " .. path)
        return texture
    end

    return target
end

local function loadMapTexture()
    return loadTexture(Config.Map.ImageFile or "mapgenie_world_cropped.png", "map")
end

local function loadPixelTexture()
    return loadTexture("pixel.png", "pixel")
end

local function loadArrowTexture()
    return loadTexture((Config.Marker or {}).ImageFile or "MapArrowRight.png", "arrow")
end

local function findClass(shortName)
    if widgetClasses[shortName] and widgetClasses[shortName]:IsValid() then
        return widgetClasses[shortName]
    end

    local candidates = {
        "Class /Script/UMG." .. shortName,
        "/Script/UMG." .. shortName,
    }

    for _, candidate in ipairs(candidates) do
        local class = StaticFindObject(candidate)
        if class and class:IsValid() then
            widgetClasses[shortName] = class
            return class
        end
    end

    log("UMG class not found: " .. shortName)
    return CreateInvalidObject()
end

local function constructWidget(shortName, outer)
    local class = findClass(shortName)
    if not class:IsValid() or not outer or not outer:IsValid() then return CreateInvalidObject() end

    local widget = safeCall("StaticConstructObject(" .. shortName .. ")", function()
        return StaticConstructObject(class, outer)
    end)

    if widget and widget:IsValid() then return widget end
    return CreateInvalidObject()
end

local function findHudScreen()
    local controller = UEHelpers.GetPlayerController()
    if controller:IsValid() and controller.MyHUD and controller.MyHUD:IsValid() then
        local hud = controller.MyHUD
        if hud.HUDScreen and hud.HUDScreen:IsValid() then return hud.HUDScreen end
    end

    local screen = FindFirstOf("WBP_HUDScreen_C")
    if screen and screen:IsValid() then return screen end

    screen = FindFirstOf("WBP_HUDScreen")
    if screen and screen:IsValid() then return screen end

    return CreateInvalidObject()
end

local function getRootWidget(hudScreen)
    if not hudScreen or not hudScreen:IsValid() then return CreateInvalidObject() end
    if hudScreen.WidgetTree and hudScreen.WidgetTree:IsValid() and hudScreen.WidgetTree.RootWidget and hudScreen.WidgetTree.RootWidget:IsValid() then
        return hudScreen.WidgetTree.RootWidget
    end
    return CreateInvalidObject()
end

local function findMainScreen()
    local screen = FindFirstOf("WBP_MainScreen_C")
    if screen and screen:IsValid() then return screen end

    screen = FindFirstOf("WBP_MainScreen")
    if screen and screen:IsValid() then return screen end

    return CreateInvalidObject()
end

local function getOverlayRootAndOuter(hudScreen)
    local mainScreen = findMainScreen()
    if mainScreen:IsValid() then
        local outer = mainScreen.WidgetTree and mainScreen.WidgetTree:IsValid() and mainScreen.WidgetTree or mainScreen
        if mainScreen.Layers and mainScreen.Layers:IsValid() then
            return mainScreen.Layers, outer
        end

        local mainRoot = getRootWidget(mainScreen)
        if mainRoot:IsValid() then return mainRoot, outer end
    end

    local hudRoot = getRootWidget(hudScreen)
    local hudOuter = hudScreen.WidgetTree and hudScreen.WidgetTree:IsValid() and hudScreen.WidgetTree or hudScreen
    return hudRoot, hudOuter
end

local function addToCanvas(parent, child)
    if not parent or not parent:IsValid() or not child or not child:IsValid() then return nil end

    local slot = safeCall("AddChildToCanvas", function()
        return parent:AddChildToCanvas(child)
    end)
    if slot and slot:IsValid() then return slot end

    slot = safeCall("AddChild", function()
        return parent:AddChild(child)
    end)
    if slot and slot:IsValid() then return slot end

    return nil
end

local function setWidgetVisibility(widget, visible)
    if widget and widget:IsValid() then
        widget:SetVisibility(visible and VISIBLE or HIDDEN)
    end
end

local function setCachedWidgetVisibility(cacheField, widget, visible)
    if overlay[cacheField] == visible then return end
    setWidgetVisibility(widget, visible)
    overlay[cacheField] = visible
end

local function setMarkerVisibility(visible)
    if overlay.lastMarkerVisible == visible then return end
    setWidgetVisibility(overlay.marker, visible)
    overlay.lastMarkerVisible = visible
end

local function setImageTexture(image, texture, tint)
    if not image or not image:IsValid() or not texture or not texture:IsValid() then return end
    safeCall("SetBrushFromTexture", function() image:SetBrushFromTexture(texture, false) end)
    safeCall("SetColorAndOpacity", function() image:SetColorAndOpacity(tint or { R = 1.0, G = 1.0, B = 1.0, A = 1.0 }) end)
end

local function createImage(parent, outer, zOrder, texture, tint)
    local image = constructWidget("Image", outer or parent)
    if not image:IsValid() then return CreateInvalidObject(), nil end

    local slot = addToCanvas(parent, image)
    if slot and slot:IsValid() then slot:SetZOrder(zOrder or 0) end
    setImageTexture(image, texture, tint)
    image:SetVisibility(VISIBLE)
    return image, slot
end

local function setSlotAnchors(slot, minX, minY, maxX, maxY, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetMinimum(vec2(minX, minY))
    slot:SetMaximum(vec2(maxX, maxY))
    slot:SetAlignment(vec2(0.0, 0.0))
    slot:SetAutoSize(false)
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotFill(slot, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetMinimum(vec2(0.0, 0.0))
    slot:SetMaximum(vec2(1.0, 1.0))
    slot:SetPosition(vec2(0.0, 0.0))
    slot:SetSize(vec2(0.0, 0.0))
    slot:SetAlignment(vec2(0.0, 0.0))
    slot:SetAutoSize(false)
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotTopLeft(slot, zOrder)
    setSlotAnchors(slot, 0.0, 0.0, 0.0, 0.0, zOrder)
end

local function attachOverlay()
    local hudScreen = findHudScreen()
    if not hudScreen:IsValid() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("WBP_HUDScreen is not available yet, waiting...")
        end
        return false
    end

    local root, widgetOuter = getOverlayRootAndOuter(hudScreen)
    if not root:IsValid() then
        if not attachAttemptLogged then
            attachAttemptLogged = true
            log("HUD/MainScreen RootWidget not found, waiting...")
        end
        return false
    end

    if overlay.canvas:IsValid() and sameObject(overlay.hudScreen, hudScreen) and sameObject(overlay.root, root) then return true end
    if overlay.canvas:IsValid() then detachOverlay(false) end

    overlay.hudScreen = hudScreen
    overlay.root = root

    overlay.canvas = constructWidget("CanvasPanel", widgetOuter)
    if not overlay.canvas:IsValid() then return false end

    overlay.canvasSlot = addToCanvas(root, overlay.canvas)
    if not overlay.canvasSlot then
        log("Failed to add CanvasPanel to HUD root: " .. root:GetFullName())
        overlay.canvas = CreateInvalidObject()
        return false
    end
    setSlotFill(overlay.canvasSlot, 9999)

    resetOverlayCaches()
    overlay.lastCanvasVisible = false

    local pixel = loadPixelTexture()
    local map = loadMapTexture()

    overlay.dim, overlay.dimSlot = createImage(overlay.canvas, widgetOuter, 980, pixel, COLOR_BLACK)
    setSlotFill(overlay.dimSlot, 980)
    overlay.map, overlay.mapSlot = createImage(overlay.canvas, widgetOuter, 990, map, COLOR_WHITE)
    setSlotTopLeft(overlay.mapSlot, 990)
    overlay.mapTextureApplied = map:IsValid()
    overlay.borderTop, overlay.borderTopSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderTopSlot, 991)
    overlay.borderRight, overlay.borderRightSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderRightSlot, 991)
    overlay.borderBottom, overlay.borderBottomSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderBottomSlot, 991)
    overlay.borderLeft, overlay.borderLeftSlot = createImage(overlay.canvas, widgetOuter, 991, pixel, COLOR_BORDER)
    setSlotTopLeft(overlay.borderLeftSlot, 991)
    local arrow = loadArrowTexture()
    overlay.marker, overlay.markerSlot = createImage(overlay.canvas, widgetOuter, 1001, arrow, COLOR_MARKER)
    setSlotTopLeft(overlay.markerSlot, 1001)
    overlay.markerTextureApplied = arrow:IsValid()

    overlay.marker:SetRenderTransformPivot(vec2(0.5, 0.5))
    overlay.canvas:SetVisibility(HIDDEN)

    if not overlayAttachedLogged then
        overlayAttachedLogged = true
        log("UMG overlay attached to HUD: " .. root:GetFullName())
    end

    return true
end

local function ensureOverlayAttached()
    if overlay.canvas:IsValid() then return true end
    return attachOverlay()
end

local function setSlotRect(slot, x, y, width, height, zOrder)
    if not slot or not slot:IsValid() then return end
    slot:SetPosition(vec2(x, y))
    slot:SetSize(vec2(width, height))
    if zOrder then slot:SetZOrder(zOrder) end
end

local function setSlotPosition(slot, x, y)
    if not slot or not slot:IsValid() then return end
    slot:SetPosition(vec2(x, y))
end

local function getViewportSize()
    local world = UEHelpers.GetWorld()
    local layout = getWidgetLayoutLibrary()
    if world:IsValid() and layout:IsValid() then
        local size = safeCall("GetViewportSize", function()
            return layout:GetViewportSize(world)
        end)
        if size and size.X and size.Y and size.X > 0 and size.Y > 0 then
            return size.X, size.Y
        end
    end
    return 1920, 1080
end

local function getViewportPollSampleCount()
    local interval = Config.UpdateIntervalMs or 100
    local pollInterval = Config.ViewportPollIntervalMs or 1000
    if interval <= 0 then return 10 end
    local count = math.floor((pollInterval / interval) + 0.5)
    if count < 1 then return 1 end
    return count
end

local function getCachedViewportSize(force)
    if force or viewportDirty or viewportPollCountdown <= 0 then
        cachedScreenW, cachedScreenH = getViewportSize()
        viewportDirty = false
        viewportPollCountdown = getViewportPollSampleCount()
    else
        viewportPollCountdown = viewportPollCountdown - 1
    end

    return cachedScreenW, cachedScreenH
end

local function getAspectRatio()
    local width = Config.Map.ImageWidth or 1
    local height = Config.Map.ImageHeight or 1
    if height == 0 then return 1.0 end
    return width / height
end

local function fitToAspect(maxW, maxH)
    local aspect = getAspectRatio()
    local width = maxW
    local height = width / aspect
    if height > maxH then
        height = maxH
        width = height * aspect
    end
    return width, height
end

local function getLayoutBox(layout, screenW, screenH)
    local maxW = layout.Width or (screenW * (layout.WidthRatio or 0.25))
    local maxH = layout.Height or (screenH * (layout.HeightRatio or 0.25))
    local width, height = fitToAspect(maxW, maxH)
    local anchor = layout.Anchor or "TopRight"
    local x = layout.X or 0
    local y = layout.Y or 0

    if anchor == "TopRight" then
        x = screenW - width - (layout.MarginRight or 16)
        y = layout.MarginTop or 16
    elseif anchor == "TopLeft" then
        x = layout.MarginLeft or 16
        y = layout.MarginTop or 16
    elseif anchor == "BottomRight" then
        x = screenW - width - (layout.MarginRight or 16)
        y = screenH - height - (layout.MarginBottom or 16)
    elseif anchor == "BottomLeft" then
        x = layout.MarginLeft or 16
        y = screenH - height - (layout.MarginBottom or 16)
    elseif anchor == "Center" then
        x = ((screenW - width) / 2.0) + (layout.OffsetX or 0)
        y = ((screenH - height) / 2.0) + (layout.OffsetY or 0)
    end

    return x, y, width, height
end

local function getAxisValue(vector, axisName)
    if not vector then return nil end
    return vector[axisName or "X"]
end

local function getBoundsForLocation(worldX, worldY)
    local mapConfig = Config.Map
    if mapConfig.AutoCenterOnFirstPlayerPosition ~= false then
        if not runtimeBounds then
            local spanX = mapConfig.AutoCenterSpanX or (mapConfig.WorldMaxX - mapConfig.WorldMinX)
            local spanY = mapConfig.AutoCenterSpanY or (mapConfig.WorldMaxY - mapConfig.WorldMinY)
            local initialU = clamp(mapConfig.InitialMapU or 0.5, 0.0, 1.0)
            local initialV = clamp(mapConfig.InitialMapV or 0.5, 0.0, 1.0)
            if mapConfig.InvertVertical ~= false then initialV = 1.0 - initialV end

            runtimeBounds = {
                MinX = worldX - (spanX * initialU),
                MaxX = worldX + (spanX * (1.0 - initialU)),
                MinY = worldY - (spanY * initialV),
                MaxY = worldY + (spanY * (1.0 - initialV)),
            }

            if not calibrationLogged then
                calibrationLogged = true
                log(string.format("Auto calibration: player=(%.1f, %.1f), bounds X=%.1f..%.1f Y=%.1f..%.1f", worldX, worldY, runtimeBounds.MinX, runtimeBounds.MaxX, runtimeBounds.MinY, runtimeBounds.MaxY))
            end
        end
        return runtimeBounds
    end

    return configuredBounds
end

local function mercatorY(lat)
    local rad = lat * math.pi / 180.0
    return (1.0 - (math.log(math.tan(rad) + (1.0 / math.cos(rad))) / math.pi)) / 2.0
end

local function getMapGenieProjection()
    if mapGenieProjection then return mapGenieProjection end

    local mapConfig = Config.Map
    local west = mapConfig.BoundsWest
    local east = mapConfig.BoundsEast
    local south = mapConfig.BoundsSouth
    local north = mapConfig.BoundsNorth
    if not west or not east or not south or not north or east == west or north == south then
        mapGenieProjection = { Valid = false }
        return mapGenieProjection
    end

    local top = mercatorY(north)
    local bottom = mercatorY(south)
    if bottom == top then
        mapGenieProjection = { Valid = false }
        return mapGenieProjection
    end

    mapGenieProjection = {
        Valid = true,
        West = west,
        Top = top,
        InvLngRange = 1.0 / (east - west),
        InvMercatorRange = 1.0 / (bottom - top),
    }
    return mapGenieProjection
end

local function worldToMapGenieUV(worldX, worldY)
    local mapConfig = Config.Map
    local projection = getMapGenieProjection()
    if not projection.Valid then return nil, nil end

    local lng = (worldX * mapConfig.LngFromXScale) + mapConfig.LngFromXOffset
    local lat = (worldY * mapConfig.LatFromYScale) + mapConfig.LatFromYOffset
    local u = (lng - projection.West) * projection.InvLngRange
    local v = (mercatorY(lat) - projection.Top) * projection.InvMercatorRange

    if mapConfig.ClampMarkerToMap ~= false then
        u = clamp(u, 0.0, 1.0)
        v = clamp(v, 0.0, 1.0)
    end

    return u, v
end

local function getPlayerLocationAndForward()
    pawnCheckCountdown = pawnCheckCountdown - 1
    if pawnCheckCountdown <= 0 or not cachedPawn:IsValid() then
        cachedPawn = UEHelpers.GetPlayer()
        pawnCheckCountdown = PAWN_CHECK_INTERVAL
    end
    if not cachedPawn:IsValid() then return nil, nil end
    return cachedPawn:K2_GetActorLocation(), cachedPawn:GetActorForwardVector()
end

local function sampleToMapPoint(sample, mapX, mapY, mapW, mapH, out)
    local mapConfig = Config.Map
    local u, v

    if mapConfig.ProjectionMode == "MapGenie" then
        u, v = worldToMapGenieUV(sample.worldX, sample.worldY)
        if not u or not v then return nil end
    else
        local bounds = getBoundsForLocation(sample.worldX, sample.worldY)
        local rangeX = bounds.MaxX - bounds.MinX
        local rangeY = bounds.MaxY - bounds.MinY
        if rangeX == 0 or rangeY == 0 then return nil end

        u = (sample.worldX - bounds.MinX) / rangeX
        v = (sample.worldY - bounds.MinY) / rangeY
        if mapConfig.InvertVertical ~= false then v = 1.0 - v end
        if mapConfig.ClampMarkerToMap ~= false then
            u = clamp(u, 0.0, 1.0)
            v = clamp(v, 0.0, 1.0)
        end
    end

    out.X = mapX + (u * mapW)
    out.Y = mapY + (v * mapH)
    out.ForwardX = sample.forwardX
    out.ForwardY = sample.forwardY
    return out
end

local function isMapActive()
    return largeMapOpen or (mapVisible and Config.Minimap and Config.Minimap.Enabled ~= false)
end

local function needsHiddenApply()
    return overlay.canvas:IsValid() and overlay.lastCanvasVisible ~= false
end

local function markOverlayStateDirty(forceViewport)
    overlayGeneration = overlayGeneration + 1
    resetOverlayCaches()
    lastWorldX = nil
    if forceViewport ~= false then viewportDirty = true end
end

local function hasPlayerMoved(worldX, worldY, forwardX, forwardY)
    if not lastWorldX then return true end
    local threshold = (Config.Marker or {}).WorldMoveThreshold or 50.0
    local dx = worldX - lastWorldX
    local dy = worldY - lastWorldY
    if (dx * dx + dy * dy) >= (threshold * threshold) then return true end
    local dfx = forwardX - (lastForwardX or 0)
    local dfy = forwardY - (lastForwardY or 0)
    if (dfx * dfx + dfy * dfy) > 0.001 then return true end
    return false
end

local function collectFrameSample()
    local active = isMapActive()
    if not active and not needsHiddenApply() then return nil end
    if not ensureOverlayAttached() then return nil end

    local screenW, screenH = getCachedViewportSize(viewportDirty)
    local sample = frameSample
    sample.generation = overlayGeneration
    sample.screenW = screenW
    sample.screenH = screenH

    if not active then
        sample.hidden = true
        return sample
    end

    local location, forward = getPlayerLocationAndForward()
    if not location then return nil end

    local worldX = getAxisValue(location, Config.Map.HorizontalAxis) or 0.0
    local worldY = getAxisValue(location, Config.Map.VerticalAxis) or 0.0
    local forwardX = forward and (getAxisValue(forward, Config.Map.HorizontalAxis) or 1.0) or 1.0
    local forwardY = forward and (getAxisValue(forward, Config.Map.VerticalAxis) or 0.0) or 0.0

    if not hasPlayerMoved(worldX, worldY, forwardX, forwardY) and not viewportDirty then
        return nil
    end

    lastWorldX = worldX
    lastWorldY = worldY
    lastForwardX = forwardX
    lastForwardY = forwardY

    sample.hidden = false
    sample.worldX = worldX
    sample.worldY = worldY
    sample.forwardX = forwardX
    sample.forwardY = forwardY

    return sample
end

local function buildDrawState(sample)
    local state = drawState
    local shouldShow = isMapActive()

    state.generation = sample.generation
    state.shouldShow = shouldShow and not sample.hidden
    state.largeMapOpen = largeMapOpen
    state.screenW = sample.screenW
    state.screenH = sample.screenH
    state.layout = nil
    state.point = nil
    state.markerXKey = nil
    state.markerYKey = nil
    state.markerAngleKey = nil
    state.markerSize = nil
    state.angle = 0.0
    state.angleKey = nil

    if not shouldShow or sample.hidden then
        state.shouldShow = false
        return state
    end

    local layout = largeMapOpen and Config.LargeMap or Config.Minimap
    local x, y, width, height = getLayoutBox(layout, sample.screenW, sample.screenH)
    local thickness = layout.BorderThickness or 2
    local point = nil
    local angle = 0.0
    local angleKey = 0

    if shouldShow then
        point = sampleToMapPoint(sample, x, y, width, height, mapPoint)
        if point then
            local forwardX = point.ForwardX or 1.0
            local forwardY = point.ForwardY or 0.0
            if Config.Map.ProjectionMode ~= "MapGenie" and Config.Map.InvertVertical ~= false then forwardY = -forwardY end
            angle = math.deg(math.atan(forwardY, forwardX))

            local marker = Config.Marker or {}
            local moveThreshold = marker.MoveThresholdPixels or 1
            local headingThreshold = marker.HeadingThresholdDegrees or 1
            angleKey = quantize(angle, headingThreshold)
            state.markerXKey = quantize(point.X, moveThreshold)
            state.markerYKey = quantize(point.Y, moveThreshold)
            state.markerAngleKey = angleKey
            state.markerSize = marker.Size or 8
        end
    end

    state.x = x
    state.y = y
    state.width = width
    state.height = height
    state.thickness = thickness
    state.layout = layout
    state.layoutXKey = math.floor(x)
    state.layoutYKey = math.floor(y)
    state.layoutWidthKey = math.floor(width)
    state.layoutHeightKey = math.floor(height)
    state.layoutMapAlpha = layout.MapAlpha or 1.0
    state.layoutBackgroundAlpha = layout.BackgroundAlpha or 0.45
    state.layoutDimVisible = largeMapOpen and layout.DimBackground ~= false
    state.point = point
    state.angle = angle
    state.angleKey = angleKey
    return state
end

local function hasLayoutChanged(state)
    return overlay.lastLayoutLarge ~= state.largeMapOpen
        or overlay.lastLayoutScreenW ~= state.screenW
        or overlay.lastLayoutScreenH ~= state.screenH
        or overlay.lastLayoutXKey ~= state.layoutXKey
        or overlay.lastLayoutYKey ~= state.layoutYKey
        or overlay.lastLayoutWidthKey ~= state.layoutWidthKey
        or overlay.lastLayoutHeightKey ~= state.layoutHeightKey
        or overlay.lastLayoutMapAlpha ~= state.layoutMapAlpha
        or overlay.lastLayoutBackgroundAlpha ~= state.layoutBackgroundAlpha
        or overlay.lastLayoutBorderThickness ~= state.thickness
        or overlay.lastLayoutDimVisible ~= state.layoutDimVisible
end

local function rememberLayoutState(state)
    overlay.lastLayoutLarge = state.largeMapOpen
    overlay.lastLayoutScreenW = state.screenW
    overlay.lastLayoutScreenH = state.screenH
    overlay.lastLayoutXKey = state.layoutXKey
    overlay.lastLayoutYKey = state.layoutYKey
    overlay.lastLayoutWidthKey = state.layoutWidthKey
    overlay.lastLayoutHeightKey = state.layoutHeightKey
    overlay.lastLayoutMapAlpha = state.layoutMapAlpha
    overlay.lastLayoutBackgroundAlpha = state.layoutBackgroundAlpha
    overlay.lastLayoutBorderThickness = state.thickness
    overlay.lastLayoutDimVisible = state.layoutDimVisible
end

local function applyDrawState(state)
    if not state then return end
    if state.generation ~= overlayGeneration then return end
    if not ensureOverlayAttached() then return end

    setCachedWidgetVisibility("lastCanvasVisible", overlay.canvas, state.shouldShow)
    if not state.shouldShow then
        return
    end

    local layout = state.layout
    local layoutChanged = hasLayoutChanged(state)

    if layoutChanged and overlay.canvasSlot and overlay.canvasSlot:IsValid() then
        setSlotFill(overlay.canvasSlot, 9999)
    end

    if not overlay.mapTextureApplied then
        local map = loadMapTexture()
        if map:IsValid() then
            COLOR_WHITE.A = layout.MapAlpha or 1.0
            setImageTexture(overlay.map, map, COLOR_WHITE)
            COLOR_WHITE.A = 1.0
            overlay.mapTextureApplied = true
        end
    elseif layoutChanged and overlay.map:IsValid() then
        COLOR_WHITE.A = layout.MapAlpha or 1.0
        overlay.map:SetColorAndOpacity(COLOR_WHITE)
        COLOR_WHITE.A = 1.0
    end

    if not overlay.markerTextureApplied then
        local arrow = loadArrowTexture()
        if arrow:IsValid() then
            setImageTexture(overlay.marker, arrow, COLOR_MARKER)
            overlay.markerTextureApplied = true
        end
    end

    if layoutChanged then
        rememberLayoutState(state)
        setCachedWidgetVisibility("lastDimVisible", overlay.dim, state.layoutDimVisible)
        setSlotFill(overlay.dimSlot, 980)
        if overlay.dim:IsValid() then
            COLOR_BLACK.A = layout.BackgroundAlpha or 0.45
            overlay.dim:SetColorAndOpacity(COLOR_BLACK)
        end

        setSlotRect(overlay.mapSlot, state.x, state.y, state.width, state.height, 990)
        setSlotRect(overlay.borderTopSlot, state.x, state.y, state.width, state.thickness, 991)
        setSlotRect(overlay.borderRightSlot, state.x + state.width - state.thickness, state.y, state.thickness, state.height, 991)
        setSlotRect(overlay.borderBottomSlot, state.x, state.y + state.height - state.thickness, state.width, state.thickness, 991)
        setSlotRect(overlay.borderLeftSlot, state.x, state.y, state.thickness, state.height, 991)
    end

    local hasPoint = state.point ~= nil
    setMarkerVisibility(hasPoint)
    if not hasPoint then
        return
    end

    local size = state.markerSize or 8
    local markerChanged = overlay.lastMarkerXKey ~= state.markerXKey
        or overlay.lastMarkerYKey ~= state.markerYKey
        or overlay.lastMarkerAngleKey ~= state.markerAngleKey
        or overlay.lastMarkerSize ~= size
    if not markerChanged then
        return
    end

    local shapeChanged = overlay.lastMarkerSize ~= size
    overlay.lastMarkerXKey = state.markerXKey
    overlay.lastMarkerYKey = state.markerYKey
    overlay.lastMarkerAngleKey = state.markerAngleKey
    overlay.lastMarkerSize = size

    if shapeChanged then
        setSlotRect(overlay.markerSlot, state.point.X - size, state.point.Y - size, size * 2, size * 2, 1001)
    else
        setSlotPosition(overlay.markerSlot, state.point.X - size, state.point.Y - size)
    end

    if overlay.lastHeadingAngleKey ~= state.angleKey then
        overlay.lastHeadingAngleKey = state.angleKey
        overlay.marker:SetRenderTransformAngle(state.angle)
    end
end

local function processFrameSample(sample)
    if not sample then return end
    local state = buildDrawState(sample)
    applyDrawState(state)
end

local function resetOverlay()
    detachOverlay(true)
    markOverlayStateDirty(true)
    runtimeBounds = nil
    overlayAttachedLogged = false
    attachAttemptLogged = false
    textureLoadAttempted = false
    pixelLoadAttempted = false
    arrowLoadAttempted = false
    mapTexture = CreateInvalidObject()
    pixelTexture = CreateInvalidObject()
    arrowTexture = CreateInvalidObject()
    cachedPawn = CreateInvalidObject()
    pawnCheckCountdown = 0
    viewportPollCountdown = 0
    lastWorldX = nil
    lastWorldY = nil
    lastForwardX = nil
    lastForwardY = nil
end

local function gameThreadUpdate()
    sampleQueued = false
    local sample = collectFrameSample()
    if sample then
        processFrameSample(sample)
    end
end

local function gameThreadUpdateSafe()
    sampleQueued = false
    local ok, err = pcall(gameThreadUpdate)
    if not ok and not updateErrorLogged then
        updateErrorLogged = true
        log("Update failed: " .. tostring(err))
    end
end

local function requestUpdate()
    if sampleQueued then return end
    if not isMapActive() and not needsHiddenApply() then return end

    sampleQueued = true
    ExecuteInGameThread(gameThreadUpdateSafe)
end

local function translateModifiers(modifierNames)
    local translated = {}
    if type(modifierNames) ~= "table" then return translated end

    for _, modifierName in ipairs(modifierNames) do
        local modifier = ModifierKey[modifierName]
        if modifier then
            translated[#translated + 1] = modifier
        else
            log("Invalid modifier in config: " .. tostring(modifierName))
        end
    end

    return translated
end

local function registerConfiguredKey(label, keyName, modifierNames, callback)
    if not keyName or keyName == "" then return end

    local key = Key[keyName]
    if not key then
        log("Invalid key for " .. label .. ": " .. tostring(keyName))
        return
    end

    local modifiers = translateModifiers(modifierNames)
    if #modifiers > 0 then
        RegisterKeyBind(key, modifiers, callback)
    else
        RegisterKeyBind(key, callback)
    end

    log(label .. " bind: " .. keyName)
end

registerConfiguredKey("OpenMap", Config.OpenMapKey, Config.OpenMapModifiers, function()
    if openToggleLocked then return end
    openToggleLocked = true
    lockKeyForDebounce(function() openToggleLocked = false end)

    if largeMapOpen then
        largeMapOpen = false
        mapVisible = true
    else
        largeMapOpen = true
        mapVisible = true
    end
    log("Large map " .. (largeMapOpen and "opened" or "closed"))
    markOverlayStateDirty(true)
    requestUpdate()
end)

registerConfiguredKey("HideMap", Config.HideMapKey, Config.HideMapModifiers, function()
    if hideToggleLocked then return end
    hideToggleLocked = true
    lockKeyForDebounce(function() hideToggleLocked = false end)

    mapVisible = not mapVisible
    if not mapVisible then largeMapOpen = false end
    log("Minimap " .. (mapVisible and "shown" or "hidden"))
    markOverlayStateDirty(true)
    requestUpdate()
end)

RegisterLoadMapPostHook(function()
    resetOverlay()
    requestUpdate()
end)

LoopAsync(Config.UpdateIntervalMs or 100, function()
    requestUpdate()
    return false
end)

requestUpdate()
log("Loaded. UMG rendering active. M opens/closes the large map, H hides/shows the minimap.")
