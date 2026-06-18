package = 'crush-catalog'
version = 'scm-1'

source = {
    url = 'git://github.com/jasondentler/crush-catalog',
}

description = {
    summary = 'Lightroom Classic plugin for Wild Catalog identification',
    license = 'Apache-2.0',
}

dependencies = {
    'lua >= 5.1',
    'busted >= 2.2.0-1',
}

build = {
    type = 'none',
}
