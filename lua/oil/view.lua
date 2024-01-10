local uv = vim.uv or vim.loop
local cache = require("oil.cache")
local columns = require("oil.columns")
local config = require("oil.config")
local constants = require("oil.constants")
local fs = require("oil.fs")
local keymap_util = require("oil.keymap_util")
local loading = require("oil.loading")
local util = require("oil.util")
local M = {}

local FIELD_ID = constants.FIELD_ID
local FIELD_NAME = constants.FIELD_NAME
local FIELD_TYPE = constants.FIELD_TYPE
local FIELD_META = constants.FIELD_META

-- map of path->last entry under cursor
local last_cursor_entry = {}

---@param name string
---@param bufnr integer
---@return boolean
M.should_display = function(name, bufnr)
  return not config.view_options.is_always_hidden(name, bufnr)
    and (not config.view_options.is_hidden_file(name, bufnr) or config.view_options.show_hidden)
end

---@param bufname string
---@param name nil|string
M.set_last_cursor = function(bufname, name)
  last_cursor_entry[bufname] = name
end

---Set the cursor to the last_cursor_entry if one exists
M.maybe_set_cursor = function()
  local oil = require("oil")
  local bufname = vim.api.nvim_buf_get_name(0)
  local entry_name = last_cursor_entry[bufname]
  if not entry_name then
    return
  end
  local line_count = vim.api.nvim_buf_line_count(0)
  for lnum = 1, line_count do
    local entry = oil.get_entry_on_line(0, lnum)
    if entry and entry.name == entry_name then
      local line = vim.api.nvim_buf_get_lines(0, lnum - 1, lnum, true)[1]
      local id_str = line:match("^/(%d+)")
      local col = line:find(entry_name, 1, true) or (id_str:len() + 1)
      vim.api.nvim_win_set_cursor(0, { lnum, col - 1 })
      M.set_last_cursor(bufname, nil)
      break
    end
  end
end

---@param bufname string
---@return nil|string
M.get_last_cursor = function(bufname)
  return last_cursor_entry[bufname]
end

local function are_any_modified()
  local buffers = M.get_all_buffers()
  for _, bufnr in ipairs(buffers) do
    if vim.bo[bufnr].modified then
      return true
    end
  end
  return false
end

M.toggle_hidden = function()
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot toggle hidden files when you have unsaved changes", vim.log.levels.WARN)
  else
    config.view_options.show_hidden = not config.view_options.show_hidden
    M.rerender_all_oil_buffers({ refetch = false })
  end
end

---@param is_hidden_file fun(filename: string, bufnr: nil|integer): boolean
M.set_is_hidden_file = function(is_hidden_file)
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot change is_hidden_file when you have unsaved changes", vim.log.levels.WARN)
  else
    config.view_options.is_hidden_file = is_hidden_file
    M.rerender_all_oil_buffers({ refetch = false })
  end
end

M.set_columns = function(cols)
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot change columns when you have unsaved changes", vim.log.levels.WARN)
  else
    config.columns = cols
    -- TODO only refetch if we don't have all the necessary data for the columns
    M.rerender_all_oil_buffers({ refetch = true })
  end
end

M.set_sort = function(new_sort)
  local any_modified = are_any_modified()
  if any_modified then
    vim.notify("Cannot change sorting when you have unsaved changes", vim.log.levels.WARN)
  else
    config.view_options.sort = new_sort
    -- TODO only refetch if we don't have all the necessary data for the columns
    M.rerender_all_oil_buffers({ refetch = true })
  end
end

-- List of bufnrs
local session = {}

---@return integer[]
M.get_all_buffers = function()
  return vim.tbl_filter(vim.api.nvim_buf_is_loaded, vim.tbl_keys(session))
end

local buffers_locked = false
---Make all oil buffers nomodifiable
M.lock_buffers = function()
  buffers_locked = true
  for bufnr in pairs(session) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      vim.bo[bufnr].modifiable = false
    end
  end
end

---Restore normal modifiable settings for oil buffers
M.unlock_buffers = function()
  buffers_locked = false
  for bufnr in pairs(session) do
    if vim.api.nvim_buf_is_loaded(bufnr) then
      local adapter = util.get_adapter(bufnr)
      if adapter then
        vim.bo[bufnr].modifiable = adapter.is_modifiable(bufnr)
      end
    end
  end
end

---@param opts? table
---@param callback? fun(err: nil|string)
---@note
--- This DISCARDS ALL MODIFICATIONS a user has made to oil buffers
M.rerender_all_oil_buffers = function(opts, callback)
  opts = opts or {}
  local buffers = M.get_all_buffers()
  local hidden_buffers = {}
  for _, bufnr in ipairs(buffers) do
    hidden_buffers[bufnr] = true
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      hidden_buffers[vim.api.nvim_win_get_buf(winid)] = nil
    end
  end
  local cb = util.cb_collect(#buffers, callback or function() end)
  for _, bufnr in ipairs(buffers) do
    if hidden_buffers[bufnr] then
      vim.b[bufnr].oil_dirty = opts
      -- We also need to mark this as nomodified so it doesn't interfere with quitting vim
      vim.bo[bufnr].modified = false
      vim.schedule(cb)
    else
      M.render_buffer_async(bufnr, opts, cb)
    end
  end
end

M.set_win_options = function()
  local winid = vim.api.nvim_get_current_win()
  for k, v in pairs(config.win_options) do
    vim.api.nvim_set_option_value(k, v, { scope = "local", win = winid })
  end
end

---Get a list of visible oil buffers and a list of hidden oil buffers
---@note
--- If any buffers are modified, return values are nil
---@return nil|integer[] visible
---@return nil|integer[] hidden
local function get_visible_hidden_buffers()
  local buffers = M.get_all_buffers()
  local hidden_buffers = {}
  for _, bufnr in ipairs(buffers) do
    if vim.bo[bufnr].modified then
      return
    end
    hidden_buffers[bufnr] = true
  end
  for _, winid in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_is_valid(winid) then
      hidden_buffers[vim.api.nvim_win_get_buf(winid)] = nil
    end
  end
  local visible_buffers = vim.tbl_filter(function(bufnr)
    return not hidden_buffers[bufnr]
  end, buffers)
  return visible_buffers, vim.tbl_keys(hidden_buffers)
end

---Delete unmodified, hidden oil buffers and if none remain, clear the cache
M.delete_hidden_buffers = function()
  local visible_buffers, hidden_buffers = get_visible_hidden_buffers()
  if not visible_buffers or not hidden_buffers or not vim.tbl_isempty(visible_buffers) then
    return
  end
  for _, bufnr in ipairs(hidden_buffers) do
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end
  cache.clear_everything()
end

---@param adapter oil.Adapter
---@param ranges table<string, integer[]>
---@return integer
local function get_first_mutable_column_col(adapter, ranges)
  local min_col = ranges.name[1]
  for col_name, start_len in pairs(ranges) do
    local start = start_len[1]
    local col_spec = columns.get_column(adapter, col_name)
    local is_col_mutable = col_spec and col_spec.perform_action ~= nil
    if is_col_mutable and start < min_col then
      min_col = start
    end
  end
  return min_col
end

---Force cursor to be after hidden/immutable columns
local function constrain_cursor()
  if not config.constrain_cursor then
    return
  end
  local parser = require("oil.mutator.parser")

  local adapter = util.get_adapter(0)
  if not adapter then
    return
  end

  local cur = vim.api.nvim_win_get_cursor(0)
  local line = vim.api.nvim_buf_get_lines(0, cur[1] - 1, cur[1], true)[1]
  local column_defs = columns.get_supported_columns(adapter)
  local result = parser.parse_line(adapter, line, column_defs)
  if result and result.ranges then
    local min_col
    if config.constrain_cursor == "editable" then
      min_col = get_first_mutable_column_col(adapter, result.ranges)
    elseif config.constrain_cursor == "name" then
      min_col = result.ranges.name[1]
    else
      error(
        string.format('Unexpected value "%s" for option constrain_cursor', config.constrain_cursor)
      )
    end
    if cur[2] < min_col then
      vim.api.nvim_win_set_cursor(0, { cur[1], min_col })
    end
  end
end

---Redraw original path virtual text for trash buffer
---@param bufnr integer
local function redraw_trash_virtual_text(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) or not vim.api.nvim_buf_is_loaded(bufnr) then
    return
  end
  local parser = require("oil.mutator.parser")
  local adapter = util.get_adapter(bufnr)
  if not adapter or adapter.name ~= "trash" then
    return
  end
  local _, buf_path = util.parse_url(vim.api.nvim_buf_get_name(bufnr))
  local os_path = fs.posix_to_os_path(assert(buf_path))
  local ns = vim.api.nvim_create_namespace("OilVtext")
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local column_defs = columns.get_supported_columns(adapter)
  for lnum, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)) do
    local result = parser.parse_line(adapter, line, column_defs)
    local entry = result and result.entry
    if entry then
      local meta = entry[FIELD_META]
      ---@type nil|oil.TrashInfo
      local trash_info = meta and meta.trash_info
      if trash_info then
        vim.api.nvim_buf_set_extmark(bufnr, ns, lnum - 1, 0, {
          virt_text = {
            {
              "➜ " .. fs.shorten_path(trash_info.original_path, os_path),
              "OilTrashSourcePath",
            },
          },
        })
      end
    end
  end
end

---@param bufnr integer
M.initialize = function(bufnr)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  vim.api.nvim_clear_autocmds({
    buffer = bufnr,
    group = "Oil",
  })
  vim.bo[bufnr].buftype = "acwrite"
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].syntax = "oil"
  vim.bo[bufnr].filetype = "oil"
  vim.b[bufnr].EditorConfig_disable = 1
  session[bufnr] = true
  for k, v in pairs(config.buf_options) do
    vim.api.nvim_buf_set_option(bufnr, k, v)
  end
  M.set_win_options()
  vim.api.nvim_create_autocmd("BufHidden", {
    desc = "Delete oil buffers when no longer in use",
    group = "Oil",
    nested = true,
    buffer = bufnr,
    callback = function()
      -- First wait a short time (100ms) for the buffer change to settle
      vim.defer_fn(function()
        local visible_buffers = get_visible_hidden_buffers()
        -- Only delete oil buffers if none of them are visible
        if visible_buffers and vim.tbl_isempty(visible_buffers) then
          -- Check if cleanup is enabled
          if type(config.cleanup_delay_ms) == "number" then
            if config.cleanup_delay_ms > 0 then
              vim.defer_fn(function()
                M.delete_hidden_buffers()
              end, config.cleanup_delay_ms)
            else
              M.delete_hidden_buffers()
            end
          end
        end
      end, 100)
    end,
  })
  vim.api.nvim_create_autocmd("BufUnload", {
    group = "Oil",
    nested = true,
    once = true,
    buffer = bufnr,
    callback = function()
      session[bufnr] = nil
    end,
  })
  vim.api.nvim_create_autocmd("BufEnter", {
    group = "Oil",
    buffer = bufnr,
    callback = function(args)
      local opts = vim.b[args.buf].oil_dirty
      if opts then
        vim.b[args.buf].oil_dirty = nil
        M.render_buffer_async(args.buf, opts)
      end
    end,
  })
  local timer
  vim.api.nvim_create_autocmd("InsertEnter", {
    desc = "Constrain oil cursor position",
    group = "Oil",
    buffer = bufnr,
    callback = function()
      -- For some reason the cursor bounces back to its original position,
      -- so we have to defer the call
      vim.schedule(constrain_cursor)
    end,
  })
  vim.api.nvim_create_autocmd("CursorMoved", {
    desc = "Update oil preview window",
    group = "Oil",
    buffer = bufnr,
    callback = function()
      local oil = require("oil")
      if vim.wo.previewwindow then
        return
      end

      constrain_cursor()

      if config.preview.update_on_cursor_moved then
        -- Debounce and update the preview window
        if timer then
          timer:again()
          return
        end
        timer = vim.loop.new_timer()
        if not timer then
          return
        end
        timer:start(10, 100, function()
          timer:stop()
          timer:close()
          timer = nil
          vim.schedule(function()
            if vim.api.nvim_get_current_buf() ~= bufnr then
              return
            end
            local entry = oil.get_cursor_entry()
            if entry then
              local winid = util.get_preview_win()
              if winid then
                if entry.id ~= vim.w[winid].oil_entry_id then
                  oil.select({ preview = true })
                end
              end
            end
          end)
        end)
      end
    end,
  })

  vim.api.nvim_create_autocmd("BufWinEnter", {
    desc = "Update preview window when displaying a buffer",
    group = "Oil",
    buffer = bufnr,
    callback = function()
      local oil = require("oil")
      if vim.wo.previewwindow then
        return
      end

      if vim.api.nvim_get_current_buf() ~= bufnr then
        return
      end
      local entry = oil.get_cursor_entry()
      if entry then
        local preview_win_id = util.get_preview_win()
        if preview_win_id then
          if entry.id ~= vim.w[preview_win_id].oil_entry_id then
            oil.select({ preview = true })
          end
        end
      end
    end,
  })

  -- Watch for TextChanged and update the trash original path extmarks
  local adapter = util.get_adapter(bufnr)
  if adapter and adapter.name == "trash" then
    local debounce_timer = assert(uv.new_timer())
    local pending = false
    vim.api.nvim_create_autocmd("TextChanged", {
      desc = "Update oil virtual text of original path",
      buffer = bufnr,
      callback = function()
        -- Respond immediately to prevent flickering, the set the timer for a "cooldown period"
        -- If this is called again during the cooldown window, we will rerender after cooldown.
        if debounce_timer:is_active() then
          pending = true
        else
          redraw_trash_virtual_text(bufnr)
        end
        debounce_timer:start(
          50,
          0,
          vim.schedule_wrap(function()
            if pending then
              pending = false
              redraw_trash_virtual_text(bufnr)
            end
          end)
        )
      end,
    })
  end
  M.render_buffer_async(bufnr, {}, function(err)
    if err then
      vim.notify(
        string.format("Error rendering oil buffer %s: %s", vim.api.nvim_buf_get_name(bufnr), err),
        vim.log.levels.ERROR
      )
    else
      vim.b[bufnr].oil_ready = true
      vim.api.nvim_exec_autocmds(
        "User",
        { pattern = "OilEnter", modeline = false, data = { buf = bufnr } }
      )
    end
  end)
  keymap_util.set_keymaps(config.keymaps, bufnr)
end

---@param adapter oil.Adapter
---@return fun(a: oil.InternalEntry, b: oil.InternalEntry): boolean
local function get_sort_function(adapter)
  local idx_funs = {}
  for _, sort_pair in ipairs(config.view_options.sort) do
    local col_name, order = unpack(sort_pair)
    if order ~= "asc" and order ~= "desc" then
      vim.notify_once(
        string.format(
          "Column '%s' has invalid sort order '%s'. Should be either 'asc' or 'desc'",
          col_name,
          order
        ),
        vim.log.levels.WARN
      )
    end
    local col = columns.get_column(adapter, col_name)
    if col and col.get_sort_value then
      table.insert(idx_funs, { col.get_sort_value, order })
    else
      vim.notify_once(
        string.format("Column '%s' does not support sorting", col_name),
        vim.log.levels.WARN
      )
    end
  end
  return function(a, b)
    for _, sort_fn in ipairs(idx_funs) do
      local get_sort_value, order = unpack(sort_fn)
      local a_val = get_sort_value(a)
      local b_val = get_sort_value(b)
      if a_val ~= b_val then
        if order == "desc" then
          return a_val > b_val
        else
          return a_val < b_val
        end
      end
    end
    return a[FIELD_NAME] < b[FIELD_NAME]
  end
end

---@param bufnr integer
---@param opts nil|table
---    jump boolean
---    jump_first boolean
---@return boolean
local function render_buffer(bufnr, opts)
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  opts = vim.tbl_extend("keep", opts or {}, {
    jump = false,
    jump_first = false,
  })
  local scheme = util.parse_url(bufname)
  local adapter = util.get_adapter(bufnr)
  if not scheme or not adapter then
    return false
  end
  local entries = cache.list_url(bufname)
  local entry_list = vim.tbl_values(entries)

  table.sort(entry_list, get_sort_function(adapter))

  local jump_idx
  if opts.jump_first then
    jump_idx = 1
  end
  local seek_after_render_found = false
  local seek_after_render = M.get_last_cursor(bufname)
  local column_defs = columns.get_supported_columns(scheme)
  local line_table = {}
  local col_width = {}
  for i in ipairs(column_defs) do
    col_width[i + 1] = 1
  end

  if M.should_display("..", bufnr) then
    local cols = M.format_entry_cols({ 0, "..", "directory" }, column_defs, col_width, adapter)
    table.insert(line_table, cols)
  end

  for _, entry in ipairs(entry_list) do
    if not M.should_display(entry[FIELD_NAME], bufnr) then
      goto continue
    end
    local cols = M.format_entry_cols(entry, column_defs, col_width, adapter)
    table.insert(line_table, cols)

    local name = entry[FIELD_NAME]
    if seek_after_render == name then
      seek_after_render_found = true
      jump_idx = #line_table
      M.set_last_cursor(bufname, nil)
    end
    ::continue::
  end

  local lines, highlights = util.render_table(line_table, col_width)

  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, true, lines)
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  util.set_highlights(bufnr, highlights)

  if opts.jump then
    -- TODO why is the schedule necessary?
    vim.schedule(function()
      for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_is_valid(winid) and vim.api.nvim_win_get_buf(winid) == bufnr then
          -- If we're not jumping to a specific lnum, use the current lnum so we can adjust the col
          local lnum = jump_idx or vim.api.nvim_win_get_cursor(winid)[1]
          local line = vim.api.nvim_buf_get_lines(bufnr, lnum - 1, lnum, true)[1]
          local id_str = line:match("^/(%d+)")
          local id = tonumber(id_str)
          if id then
            local entry = cache.get_entry_by_id(id)
            if entry then
              local name = entry[FIELD_NAME]
              local col = line:find(name, 1, true) or (id_str:len() + 1)
              vim.api.nvim_win_set_cursor(winid, { lnum, col - 1 })
            end
          end
        end
      end
    end)
  end
  return seek_after_render_found
end

---@private
---@param entry oil.InternalEntry
---@param column_defs table[]
---@param col_width integer[]
---@param adapter oil.Adapter
---@return oil.TextChunk[]
M.format_entry_cols = function(entry, column_defs, col_width, adapter)
  local name = entry[FIELD_NAME]
  local meta = entry[FIELD_META]
  if meta and meta.display_name then
    name = meta.display_name
  end
  -- First put the unique ID
  local cols = {}
  local id_key = cache.format_id(entry[FIELD_ID])
  col_width[1] = id_key:len()
  table.insert(cols, id_key)
  -- Then add all the configured columns
  for i, column in ipairs(column_defs) do
    local chunk = columns.render_col(adapter, column, entry)
    local text = type(chunk) == "table" and chunk[1] or chunk
    ---@cast text string
    col_width[i + 1] = math.max(col_width[i + 1], vim.api.nvim_strwidth(text))
    table.insert(cols, chunk)
  end
  -- Always add the entry name at the end
  local entry_type = entry[FIELD_TYPE]
  if entry_type == "directory" then
    table.insert(cols, { name .. "/", "OilDir" })
  elseif entry_type == "socket" then
    table.insert(cols, { name, "OilSocket" })
  elseif entry_type == "link" then
    local link_text
    if meta then
      if meta.link_stat and meta.link_stat.type == "directory" then
        name = name .. "/"
      end

      if meta.link then
        link_text = "->" .. " " .. meta.link
        if meta.link_stat and meta.link_stat.type == "directory" then
          link_text = util.addslash(link_text)
        end
      end
    end

    table.insert(cols, { name, "OilLink" })
    if link_text then
      table.insert(cols, { link_text, "OilLinkTarget" })
    end
  else
    table.insert(cols, { name, "OilFile" })
  end
  return cols
end

---Get the column names that are used for view and sort
---@return string[]
local function get_used_columns()
  local cols = {}
  for _, def in ipairs(config.columns) do
    local name = util.split_config(def)
    table.insert(cols, name)
  end
  for _, sort_pair in ipairs(config.view_options.sort) do
    local name = sort_pair[1]
    table.insert(cols, name)
  end
  return cols
end

---@param bufnr integer
---@param opts nil|table
---    refetch nil|boolean Defaults to true
---@param callback nil|fun(err: nil|string)
M.render_buffer_async = function(bufnr, opts, callback)
  vim.b[bufnr].oil_ready = false
  opts = vim.tbl_deep_extend("keep", opts or {}, {
    refetch = true,
  })
  if bufnr == 0 then
    bufnr = vim.api.nvim_get_current_buf()
  end
  local bufname = vim.api.nvim_buf_get_name(bufnr)
  local _, dir = util.parse_url(bufname)
  -- Undo should not return to a blank buffer
  -- Method taken from :h clear-undo
  vim.bo[bufnr].undolevels = -1
  local handle_error = vim.schedule_wrap(function(message)
    vim.bo[bufnr].undolevels = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
    util.render_text(bufnr, { "Error: " .. message })
    if callback then
      callback(message)
    else
      error(message)
    end
  end)
  if not dir then
    handle_error(string.format("Could not parse oil url '%s'", bufname))
    return
  end
  local adapter = util.get_adapter(bufnr)
  if not adapter then
    handle_error(string.format("[oil] no adapter for buffer '%s'", bufname))
    return
  end
  local start_ms = uv.hrtime() / 1e6
  local seek_after_render_found = false
  local first = true
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].modified = false
  loading.set_loading(bufnr, true)

  local finish = vim.schedule_wrap(function()
    if not vim.api.nvim_buf_is_valid(bufnr) then
      return
    end
    loading.set_loading(bufnr, false)
    render_buffer(bufnr, { jump = true })
    vim.bo[bufnr].undolevels = vim.api.nvim_get_option_value("undolevels", { scope = "global" })
    vim.bo[bufnr].modifiable = not buffers_locked and adapter.is_modifiable(bufnr)
    if callback then
      callback()
    end
  end)
  if not opts.refetch then
    finish()
    return
  end

  cache.begin_update_url(bufname)
  adapter.list(bufname, get_used_columns(), function(err, entries, fetch_more)
    loading.set_loading(bufnr, false)
    if err then
      cache.end_update_url(bufname)
      handle_error(err)
      return
    end
    if entries then
      for _, entry in ipairs(entries) do
        cache.store_entry(bufname, entry)
      end
    end
    if fetch_more then
      local now = uv.hrtime() / 1e6
      local delta = now - start_ms
      -- If we've been chugging for more than 40ms, go ahead and render what we have
      if delta > 40 then
        start_ms = now
        vim.schedule(function()
          seek_after_render_found =
            render_buffer(bufnr, { jump = not seek_after_render_found, jump_first = first })
        end)
      end
      first = false
      vim.defer_fn(fetch_more, 4)
    else
      cache.end_update_url(bufname)
      -- done iterating
      finish()
    end
  end)
end

return M
