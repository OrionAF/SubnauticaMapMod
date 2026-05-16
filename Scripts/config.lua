local Config = {
    -- Key names must match UE4SS Key.* values. Examples: "M", "H", "TAB", "F6".
    OpenMapKey = "M",
    OpenMapModifiers = {},

    HideMapKey = "H",
    HideMapModifiers = {},

    ShowMinimapAtStartup = true,
    UpdateIntervalMs = 100,
    ViewportPollIntervalMs = 1000,
    KeyDebounceMs = 600,

    Map = {
        ImageFile = "mapgenie_world_cropped.png",
        ImageWidth = 1144,
        ImageHeight = 482,

        -- MapGenie already contains exact game X/Y coordinates in location descriptions.
        -- These coefficients convert UE world X/Y to MapGenie longitude/latitude.
        ProjectionMode = "MapGenie",
        LngFromXScale = 0.0000028912681189998626,
        LngFromXOffset = -0.049961343800042045,
        LatFromYScale = -0.000002992336954998909,
        LatFromYOffset = 2.0063350541995395,
        BoundsWest = -1.13,
        BoundsEast = -0.345,
        BoundsSouth = 0.565,
        BoundsNorth = 0.895,

        -- Player marker calibration.
        -- Subnautica 2/UE positions are world units. If the marker is offset, tune
        -- these four bounds instead of changing the mod code.
        HorizontalAxis = "X",
        VerticalAxis = "Y",
        WorldMinX = -70000.0,
        WorldMaxX = 70000.0,
        WorldMinY = -70000.0,
        WorldMaxY = 70000.0,
        AutoCenterOnFirstPlayerPosition = false,
        AutoCenterSpanX = 140000.0,
        AutoCenterSpanY = 140000.0,
        InitialMapU = 0.5,
        InitialMapV = 0.5,
        InvertVertical = true,
        ClampMarkerToMap = true,
    },

    Minimap = {
        Enabled = true,
        Anchor = "TopRight",
        Width = 360,
        MarginTop = 24,
        MarginRight = 24,
        BackgroundAlpha = 0.55,
        MapAlpha = 0.92,
        BorderThickness = 2,
    },

    LargeMap = {
        Anchor = "Center",
        WidthRatio = 0.90,
        HeightRatio = 0.72,
        BackgroundAlpha = 0.88,
        MapAlpha = 1.0,
        BorderThickness = 3,
        DimBackground = true,
    },

    Marker = {
        ImageFile = "MapArrowRight.png",
        Size = 12,
        MoveThresholdPixels = 1,
        HeadingThresholdDegrees = 1,
        Color = { R = 0.0, G = 0.9, B = 1.0, A = 1.0 },
    },

    Debug = {
        LogPosition = false,
        DrawCoordinates = false,
    },
}

return Config
