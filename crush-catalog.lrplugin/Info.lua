return {
    LrSdkVersion = 5.0, -- Current recommended SDK version
    LrToolkitIdentifier = 'com.jasondentler.crushcatalog',
    LrPluginName = LOC "$$$/CrushCatalog/PluginName=Crush Catalog",
    LrPluginInfoUrl = "https://github.com/jasondentler/crush-catalog",

    LrPluginInfoProvider = "InfoProvider.lua",
    LrMetadataProvider = "MetadataProvider.lua",
    LrLibraryMenuItems = {
        {
            title = LOC "$$$/CrushCatalog/IdentifySelected=Identify Species",
            file = "IdentifySelectedPhotosTask.lua",
        },
    },

    VERSION = {
        major = 0,
        minor = 0,
        revision = 1,
        build = "202606180600"
    }
}
