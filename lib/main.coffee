{$$, SelectListView} = require('atom-space-pen-views')
{BufferedNodeProcess} = require('atom')
path = require('path')
fs = require('fs')

################################################################################
# The BuildWorker serializes and deduplicates overlapping asynchronous requests
# to the worker process. For example, if there are five compilations requested
# in a row, the first one will kick off immediately, the next three will be
# dropped, and the last one will be queued. When the first compile comes back
# it will be ignored because it's out of date and the queued compile will be
# kicked off instead.

class BuildWorker
  constructor: ({onCompile, onTooltipQuery}) ->
    @onCompile = onCompile
    @onTooltipQuery = onTooltipQuery
    @nextID = 0
    @isBusy = false
    @pendingCompile = null
    @pendingTooltipQuery = null
    @child = new BufferedNodeProcess
      command: path.join(__dirname, 'build.js')
      stdout: (line) => @onMessage(JSON.parse(line))
      stderr: (line) => throw new Error(JSON.parse(line))
      exit: (code) => throw new Error('Worker process exited with code ' + code)

  send: (message) ->
    @child.process.stdin.write(JSON.stringify(message) + '\n')

  requestCompile: (inputs) ->
    message =
      type: 'compile'
      id: @nextID++
      target: 'js'
      inputs: inputs
      stopAfterResolve: true

    # Only one request is in flight at a time so we don't waste work
    if @isBusy
      @pendingCompile = message
    else
      @isBusy = true
      @send(message)
    return message.id

  requestTooltip: (source, line, column) ->
    message =
      type: 'tooltip-query'
      id: @nextID++
      source: source
      line: line
      column: column

    # Only one request is in flight at a time so we don't waste work
    if @isBusy
      @pendingTooltipQuery = message
    else
      @isBusy = true
      @send(message)
    return message.id

  onMessage: (message) ->
    if @pendingCompile
      @send(@pendingCompile)
      return

    if @pendingTooltipQuery
      @send(@pendingTooltipQuery)
      return

    @isBusy = false
    switch message.type
      when 'compile' then @onCompile(message)
      when 'tooltip-query' then @onTooltipQuery(message)
      else throw new Error('Unexpected message type "' + message.type + '"')

################################################################################
# This tracks the top-level project folders in the editor for changes. It relies
# on the file system support in node.

class DirectoryTracker
  constructor: (onChanged) ->
    @onChanged = onChanged
    @directories = []
    @watchers = {}

  updateDirectories: (directories) ->
    changed = false

    # Remove old directories
    for directory in @directories
      if directory not in directories
        @onRemoved(directory)
        changed = true

    # Add new directories
    for directory in directories
      if directory not in @directories
        @onAdded(directory)
        changed = true

    # Send changes
    @directories = directories.slice()
    if changed
      @onChanged()

  onAdded: (directory) ->
    @watchers[directory] = fs.watch directory, recursive: true, =>
      @onChanged()

  onRemoved: (directory) ->
    @watchers[directory].close()
    delete @watchers[directory]

################################################################################
# This drives all builds in the system. A new build is started every time a file
# in a project folder is changed.

class BuildDriver
  constructor: (onBuild) ->
    @onBuild = onBuild
    @isInvalid = true
    @currentWalk = null
    @onDidChangePaths = null
    @roots = new DirectoryTracker(=> @invalidate())

  activate: ->
    @deactivate()
    @roots.updateDirectories(atom.project.getPaths())
    @onDidChangePaths = atom.project.onDidChangePaths =>
      @roots.updateDirectories(atom.project.getPaths())

  deactivate: ->
    @currentWalk?.cancel()
    @onDidChangePaths?.dispose()
    @currentWalk = null
    @onDidChangePaths = null

  invalidate: ->
    @currentWalk?.cancel()
    @currentWalk = @walkDirectories(@roots.directories, @onBuild)

  walkDirectories: (directories, callback) ->
    isCanceled = false
    result = []
    count = 0

    # Use asynchronous calls for performance
    walk = (directory) ->
      count++
      fs.readdir directory, (error, files) ->
        count--
        return if isCanceled
        files.forEach (file) ->
          return if file[0] == '.'
          joined = path.join(directory, file)
          count++
          fs.stat joined, (error, stats) ->
            count--
            return if isCanceled
            result.push(joined) if stats.isFile()
            walk(joined) if stats.isDirectory()
            done()
        done()

    # Need to know when all asynchronous calls have finished
    done = ->
      if !@isCanceled && count == 0
        callback(result)

    # Assume these directories don't overlap
    walk(directory) for directory in directories
    done()

    # Need a way to stop since it's asynchronous
    return cancel: ->
      isCanceled = true

################################################################################
# The editor attachment handles the UI interactions specific to each open file.
# It displays diagnostics from failed builds and handles tooltips.

class EditorAttachment
  constructor: (editor, plugin) ->
    @editor = editor
    @plugin = plugin
    @markers = []
    @diagnostics = {}
    @currentRange = null
    @pendingTooltipQuery = null
    @timeout = null
    @tooltip = document.createElement('div')
    @tooltip.className = 'skew-tooltip'
    @element = atom.views.getView(@editor)
    @element.addEventListener('mousemove', (e) => @onMouseMove(e))
    @element.addEventListener('mouseleave', => @hideTooltip())
    @editor.onDidChange(=> @hideTooltip())
    @editor.onDidChangeScrollLeft(=> @hideTooltip())
    @editor.onDidChangeScrollTop(=> @hideTooltip())

  detach: ->
    @hideTooltip()

  showTooltip: (range, text) ->
    @currentRange = range
    start = range.start
    pixelPos = @bufferPositionToPixelPosition([start.line, start.column])
    offset = @pixelPositionOffset()
    x = pixelPos.left + offset.left
    y = pixelPos.top + offset.top + @editor.getLineHeightInPixels() + 1
    @tooltip.style.left = x + 'px'
    @tooltip.style.top = y + 'px'
    @tooltip.textContent = text
    document.body.appendChild(@tooltip)

  hideTooltip: ->
    clearTimeout(@timeout)
    @currentRange = null
    @pendingTooltipQuery = null
    @timeout = null
    @tooltip.remove()

  onMouseMove: (e) ->
    offset = @pixelPositionOffset()
    charWidth = @editor.getDefaultCharWidth()
    {row, column} = @pixelPositionToBufferPosition(
      left: e.clientX - offset.left,
      top: e.clientY - offset.top)
    line = @editor.lineTextForBufferRow(row)

    # Since Atom clamps to the end of the line, the tooltip will always be
    # shown if the mouse is off the right side of the line. Strangely there
    # doesn't seem to be an API to detect this, so try to manually detect
    # when this case comes up.
    limit = @bufferPositionToPixelPosition([row, line.length])
    if e.clientX > limit.left + offset.left + charWidth / 2
      @hideTooltip()
      return

    # Don't hide the tooltip if the mouse moves within the hit target
    else if @currentRange
      {start, end} = @currentRange
      if row == start.line && column >= start.column && (
          start.line != end.line || column <= end.column)
        return

    # Otherwise, hide the tooltip and prepare to show a tooltip on idle
    @hideTooltip()
    @timeout = setTimeout =>
      file = @editor.getPath()
      @pendingTooltipQuery = @plugin.worker.requestTooltip(file, row, column)
    , 500

  pixelPositionOffset: ->
    privateScrollView = @element.rootElement.querySelector('.scroll-view')
    bounds = privateScrollView.getBoundingClientRect()
    return {
      left: Math.round(bounds.left) - @editor.displayBuffer.getScrollLeft()
      top: Math.round(bounds.top) - @editor.displayBuffer.getScrollTop()
    }

  pixelPositionToBufferPosition: (position) ->
    return @editor.bufferPositionForScreenPosition(
      @editor.screenPositionForPixelPosition(position))

  bufferPositionToPixelPosition: (position) ->
    return @editor.pixelPositionForScreenPosition(
      @editor.screenPositionForBufferPosition(position))

  updateDiagnostics: (diagnostics) ->
    file = @editor.getPath()
    marker.destroy() for marker in @markers
    @diagnostics = {}
    @markers = []

    # Check all relevant diagnostics
    for diagnostic in diagnostics
      range = diagnostic.range
      continue if range.source != file
      {start, end} = range
      range = [[start.line, start.column], [end.line, end.column]]

      # Annotate the diagnostics using CSS
      marker = @editor.markBufferRange(range)
      @editor.decorateMarker(marker,
        type: 'highlight',
        class: 'skew-' + diagnostic.kind)
      @markers.push(marker)

      # Create a quick way to get to all diagnostics on a given line
      @diagnostics[start.line] ||= []
      @diagnostics[start.line].push(diagnostic)

  updateTooltip: (data) ->
    if data.id == @pendingTooltipQuery
      @showTooltip(data.range, data.tooltip)

################################################################################
# The diagnostic panel lists all errors and warnings.

class DiagnosticList extends SelectListView
  constructor: ->
    super
    @errors = []
    @warnings = []
    @panel = null

  getFilterKey: ->
    return 'text'

  viewForItem: (diagnostic) ->
    source = ''
    if diagnostic.range
      start = diagnostic.range.start
      source = @friendlyRelativePath(diagnostic.range.source)
      source += ':' + (start.line + 1) + ':' + (start.column + 1)
    return $$ ->
      @li =>
        @div =>
          @span class: 'skew-' + diagnostic.kind, diagnostic.kind + ': '
          @span diagnostic.text
        @div class: 'skew-source', source

  friendlyRelativePath: (absolute) ->
    best = absolute
    for root in atom.project.getPaths()
      relative = path.relative(root, absolute)
      best = relative if relative.length < best.length
    return best

  activate: ->
    atom.commands.add('atom-workspace', 'skew:show-diagnostics', => @show())

  deactivate: ->
    @hide()

  show: ->
    @hide()
    @setItems(@errors.concat(@warnings))
    @panel = atom.workspace.addModalPanel(item: this)
    @panel.show()
    @focusFilterEditor()

  hide: ->
    panel = @panel
    @panel = null
    panel?.destroy()

  updateDiagnostics: (diagnostics) ->
    @errors = diagnostics.filter((diagnostic) -> diagnostic.kind == 'error')
    @warnings = diagnostics.filter((diagnostic) -> diagnostic.kind == 'warning')

  confirmed: (diagnostic) ->
    @hide()
    range = diagnostic.range
    if range
      atom.workspace.open(range.source,
        initialLine: range.start.line,
        initialColumn: range.start.column)

  cancelled: ->
    @hide()

################################################################################
# This handles the message in the status bar that shows the current error count.
# It doubles as a link that opens the diagnostic panel.

class StatusBarTile
  constructor: (plugin) ->
    @element = document.createElement('a')
    shortcut = if process.platform == 'darwin' then '\u2318;' else 'Ctrl+;'
    atom.tooltips.add(@element, title: 'Build Log (' + shortcut + ')')
    @updateDiagnostics([])
    @element.onclick = => plugin.diagnosticList.show()

  updateDiagnostics: (diagnostics) ->
    errors = diagnostics.reduce(((c, d) -> c + +(d.kind == 'error')), 0)
    warnings = diagnostics.reduce(((c, d) -> c + +(d.kind == 'warning')), 0)
    plural = (n, text) -> n + ' ' + text + (if n == 1 then '' else 's')

    # Construct the message
    html = []
    html.push(plural(errors, 'error')) if errors
    html.push(plural(warnings, 'warning')) if warnings

    # Update the element
    @element.style.display = if html.length then 'inline-block' else 'none'
    @element.innerHTML = html.join(', ')

################################################################################
# This is responsible for creating and destroying an EditorAttachment for each
# file in the editor as files are opened and closed.

class EditorTracker
  constructor: (plugin) ->
    @plugin = plugin
    @attachments = null
    @observation = null
    @diagnostics = []

  activate: ->
    @deactivate()
    @attachments = []
    @observation = atom.workspace.observeTextEditors (editor) =>
      attachment = new EditorAttachment(editor, @plugin)
      attachment.updateDiagnostics(@diagnostics)
      @attachments.push(attachment)
      editor.onDidDestroy =>
        index = @attachments.indexOf(attachment)
        @attachments.splice(index, 1) if index >= 0
        attachment.detach()

  deactivate: ->
    @observation?.dispose()
    @observation = null

  updateDiagnostics: (diagnostics) ->
    @diagnostics = diagnostics
    for attachment in @attachments
      attachment.updateDiagnostics(diagnostics)
    @plugin.statusBar.updateDiagnostics(diagnostics)
    @plugin.diagnosticList.updateDiagnostics(diagnostics)

  updateTooltip: (data) ->
    if data.tooltip
      for attachment in @attachments
        attachment.updateTooltip(data)

################################################################################
# This is the core of the package. It connects components at a high level.

class Plugin
  constructor: ->
    @statusBar = new StatusBarTile(@)
    @editors = new EditorTracker(@)
    @diagnosticList = new DiagnosticList
    @isActive = false

    # Only bother building if there are source files present
    @driver = new BuildDriver (files) =>
      files = files.filter((file) -> /\.sk$/.test(file))
      @isActive = files.length > 0
      if @isActive
        @worker.requestCompile(files)
      else
        @editors.updateDiagnostics([])

    # Pass the build results to the UI
    @worker = new BuildWorker
      onCompile: (result) => @editors.updateDiagnostics(result.log.diagnostics)
      onTooltipQuery: (result) => @editors.updateTooltip(result)

  activate: ->
    @editors.activate()
    @driver.activate()
    @diagnosticList.activate()

  deactivate: ->
    @editors.deactivate()
    @driver.deactivate()
    @diagnosticList.deactivate()

################################################################################

do ->
  plugin = new Plugin
  statusBarTile = null

  exports.activate = ->
    plugin.activate()

  exports.deactivate = ->
    plugin.deactivate()
    statusBarTile?.destroy()
    statusBarTile = null

  exports.consumeStatusBar = (statusBar) ->
    statusBarTile = statusBar.addLeftTile(item: plugin.statusBar.element)
