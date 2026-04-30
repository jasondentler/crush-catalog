return {
    LrSdkVersion = 5.0, -- Current recommended SDK version
    LrToolkitIdentifier = 'com.jasondentler.crushcatalog',
    LrPluginName = LOC "$$$/CrushCatalog/PluginName=Crush Catalog",
    LrPluginInfoUrl = "https://github.com/jasondentler/crush-catalog",

    -- Plug-in Manager panel
    LrPluginInfoProvider = "InfoProvider.lua",
    LrLibraryMenuItems = {{
        title = LOC "$$$/CrushCatalog/x=x",
        file = "x.lua"
    }},

    VERSION = {
        major = 0,
        minor = 0,
        revision = 1,
        build = "202604101920"
    }
}
