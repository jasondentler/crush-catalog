std = 'lua51'
codes = true

exclude_files = {
    'crush-catalog.lrplugin/JSON.lua',
}

read_globals = {
    -- Lightroom SDK globals.
    'import',
    'LOC',
    '_PLUGIN',

    -- Busted test globals.
    'describe',
    'it',
    'before_each',
    'after_each',
    'setup',
    'teardown',
    'pending',
}
