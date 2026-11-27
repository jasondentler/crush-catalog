local Dialog = {}

local function photoCount(count)
    return string.format('%d photo%s', count, count == 1 and '' or 's')
end

local function countText(value)
    return value == nil and 'Unavailable' or tostring(value)
end

local function heading(report)
    return report.canceled and 'Identification stopped' or 'Identification complete'
end

local function notes(report, selected)
    local lines = {}
    if selected > report.written then
        lines[#lines + 1] = photoCount(selected - report.written) .. ' not tagged'
    end
    if report.failed > 0 then
        lines[#lines + 1] = 'Could not process: ' .. report.failed
    end
    if report.excluded > 0 then
        lines[#lines + 1] = 'Could not prepare: ' .. report.excluded
    end
    if report.canceled then
        lines[#lines + 1] = 'Completed tags have been saved.'
    end
    if #report.warnings > 0 then
        lines[#lines + 1] = 'Some tags or review images need attention.'
    end
    return lines
end

local function textSummary(report, species, selected, elapsed)
    local lines = {
        'Photos tagged: ' .. report.written,
        'Species identified: ' .. countText(species.ranked and #species.ranked),
        'New lifers: ' .. countText(species.lifers and #species.lifers),
    }
    if species.lifers and #species.lifers > 0 then
        lines[#lines + 1] = '\nNew lifers'
        for _, row in ipairs(species.lifers) do lines[#lines + 1] = row.name end
    end
    if species.ranked and #species.ranked > 0 then
        lines[#lines + 1] = '\nMost photographed species'
        for _, row in ipairs(species.ranked) do
            lines[#lines + 1] = row.name .. ' — ' .. photoCount(row.count)
        end
    end
    lines[#lines + 1] = '\nCatalog species total: ' .. countText(species.catalogTotal)
    for _, note in ipairs(notes(report, selected)) do lines[#lines + 1] = note end
    lines[#lines + 1] = 'Completed in ' .. elapsed
    return table.concat(lines, '\n')
end

function Dialog.show(report, species, selected, elapsed, failures)
    local dialogs = import 'LrDialogs'
    local tasks = import 'LrTasks'
    local hasIssues = #failures > 0 or #report.warnings > 0
    local function details()
        local lines = {}
        for _, failure in ipairs(failures) do lines[#lines + 1] = failure end
        for _, warning in ipairs(report.warnings) do lines[#lines + 1] = warning end
        return table.concat(lines, '\n')
    end
    local ok, action = tasks.pcall(function()
        local factory = (import 'LrView').osFactory()
        local function metric(label, value)
            return factory:column {
                spacing = 4, width = 145,
                factory:static_text {
                    title = countText(value), font = '<system/bold>',
                    alignment = 'center', fill_horizontal = 1,
                },
                factory:static_text {
                    title = label, alignment = 'center', fill_horizontal = 1,
                },
            }
        end
        local function section(title, items)
            local column = { spacing = 5, fill_horizontal = 1,
                factory:static_text { title = title, font = '<system/bold>' } }
            if #items > 6 then
                local choices = {}
                for index, item in ipairs(items) do
                    choices[index] = { title = item, value = index }
                end
                column[#column + 1] = factory:simple_list {
                    items = choices, width = 465, height = 130,
                }
            else
                for _, item in ipairs(items) do
                    column[#column + 1] = factory:static_text { title = item, fill_horizontal = 1 }
                end
            end
            return factory:column(column)
        end
        local contents = {
            spacing = 12,
            factory:row {
                spacing = 12,
                metric('Photos tagged', report.written),
                metric('Species identified', species.ranked and #species.ranked),
                metric('New lifers', species.lifers and #species.lifers),
            },
        }
        local function add(view) contents[#contents + 1] = view end
        local function separator() add(factory:separator { fill_horizontal = 1 }) end
        if species.lifers and #species.lifers > 0 then
            local items = {}
            for _, row in ipairs(species.lifers) do items[#items + 1] = row.name end
            separator()
            add(section('New lifers', items))
        end
        if species.ranked and #species.ranked > 0 then
            local items = {}
            for _, row in ipairs(species.ranked) do
                items[#items + 1] = row.name .. ' — ' .. photoCount(row.count)
            end
            separator()
            add(section('Most photographed species', items))
        end
        separator()
        add(factory:static_text {
            title = 'Catalog species total: ' .. countText(species.catalogTotal),
            font = '<system/bold>',
        })
        for _, note in ipairs(notes(report, selected)) do
            add(factory:static_text { title = note })
        end
        add(factory:static_text { title = 'Completed in ' .. elapsed, size = 'small' })
        return dialogs.presentModalDialog {
            title = heading(report), contents = factory:column(contents),
            actionVerb = 'Done', cancelVerb = '< exclude >',
            otherVerb = hasIssues and 'Details' or nil, resizable = false,
        }
    end)
    if not ok then
        dialogs.message(heading(report), textSummary(report, species, selected, elapsed),
            hasIssues and 'warning' or 'info')
    end
    if hasIssues and (not ok or action == 'other') then
        dialogs.message('Photos needing attention', details(), 'warning')
    end
end

Dialog.textSummary = textSummary
return Dialog
