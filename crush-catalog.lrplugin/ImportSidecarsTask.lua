local LrTasks = import 'LrTasks'
local SidecarTask = require 'SidecarTask'

LrTasks.startAsyncTask(SidecarTask.importSelectedPhotos)
