local M = {}

local function rpc_error(code, message, data)
  error({ code = code, message = message, data = data })
end

local function is_buffer_dirty(path)
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      if name == path and vim.api.nvim_get_option_value("modified", { buf = buf }) then
        return true
      end
    end
  end
  return false
end

local function is_file_saved(result)
  return type(result) == "table"
    and type(result.content) == "table"
    and type(result.content[1]) == "table"
    and result.content[1].text == "FILE_SAVED"
end

local function make_resolution_callback(co, on_resolve)
  local fired = false
  return function(result)
    if not fired then
      fired = true
      pcall(on_resolve, is_file_saved(result))
    end
    local resumed_ok, resumed = coroutine.resume(co, result)
    local co_key = tostring(co)
    local responses = rawget(_G, "claude_deferred_responses")
    if not responses or not responses[co_key] then
      return
    end
    if resumed_ok then
      responses[co_key](resumed)
    else
      responses[co_key]({
        error = {
          code = -32603,
          message = "Internal error",
          data = "Coroutine failed: " .. tostring(resumed),
        },
      })
    end
    responses[co_key] = nil
  end
end

local function is_floating(win)
  local cfg = vim.api.nvim_win_get_config(win)
  return cfg.relative and cfg.relative ~= ""
end

local function is_editor_window(win)
  if not vim.api.nvim_win_is_valid(win) or is_floating(win) then
    return false
  end
  local buf = vim.api.nvim_win_get_buf(win)
  local bt = vim.api.nvim_get_option_value("buftype", { buf = buf })
  return bt ~= "terminal" and bt ~= "prompt"
end

local function first_non_float_window()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_is_valid(win) and not is_floating(win) then
      return win
    end
  end
  return nil
end

local function find_or_open(path)
  local buf = vim.fn.bufadd(path)
  vim.fn.bufload(buf)
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if vim.api.nvim_win_get_buf(win) == buf then
      return buf, win
    end
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    if is_editor_window(win) then
      local ok = pcall(vim.api.nvim_win_set_buf, win, buf)
      if ok then
        return buf, win
      end
    end
  end
  local non_float = first_non_float_window()
  if non_float then
    vim.api.nvim_set_current_win(non_float)
  end
  vim.cmd("belowright split")
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  return buf, win
end

local function lines_for_set(str)
  -- A trailing "\n" in the source is the EOL of the last line, not an extra empty line.
  local lines = vim.split(str, "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

local function render_overlay(buf, ns, old_lines, hunks)
  local total_new = vim.api.nvim_buf_line_count(buf)
  for _, h in ipairs(hunks) do
    local start_a, count_a, start_b, count_b = h[1], h[2], h[3], h[4]

    if count_a > 0 then
      local removed = {}
      for i = 0, count_a - 1 do
        local text = old_lines[start_a + i] or ""
        table.insert(removed, {
          { text, "DiffDelete" },
          { string.rep(" ", 500), "DiffDelete" },
        })
      end

      local anchor, above
      if count_b > 0 then
        anchor = start_b - 1
        above = true
      elseif start_b >= 1 then
        anchor = start_b - 1
        above = false
      else
        anchor = 0
        above = true
      end
      if anchor < 0 then anchor = 0 end
      if anchor >= total_new then anchor = math.max(0, total_new - 1) end

      pcall(vim.api.nvim_buf_set_extmark, buf, ns, anchor, 0, {
        virt_lines = removed,
        virt_lines_above = above,
      })
    end

    if count_b > 0 then
      local s = start_b - 1
      local e = s + count_b
      if e > total_new then e = total_new end
      if s < 0 then s = 0 end
      if s < e then
        pcall(vim.api.nvim_buf_set_extmark, buf, ns, s, 0, {
          end_row = e,
          hl_group = "DiffAdd",
          hl_eol = true,
        })
      end
    end
  end
end

local function clear_diff_ui(buf, ns, autocmd_ids, original_buftype)
  if vim.api.nvim_buf_is_valid(buf) then
    pcall(vim.api.nvim_buf_clear_namespace, buf, ns, 0, -1)
    if original_buftype ~= nil then
      pcall(vim.api.nvim_set_option_value, "buftype", original_buftype, { buf = buf })
    end
  end
  for _, id in ipairs(autocmd_ids) do
    pcall(vim.api.nvim_del_autocmd, id)
  end
end

local function restore_buffer(file_buf, is_new_file)
  if not vim.api.nvim_buf_is_valid(file_buf) then
    return
  end
  if is_new_file then
    pcall(vim.api.nvim_buf_set_lines, file_buf, 0, -1, false, {})
    pcall(vim.api.nvim_set_option_value, "modified", false, { buf = file_buf })
  else
    pcall(vim.api.nvim_buf_call, file_buf, function()
      vim.cmd("silent! edit!")
    end)
  end
end

function M.make_open_diff_blocking(diff)
  return function(old_file_path, new_file_path, new_file_contents, tab_name)
    local co, is_main = coroutine.running()
    if not co or is_main then
      rpc_error(-32000, "Internal server error", "openDiff must run in coroutine context")
    end

    pcall(diff._cleanup_diff_state, tab_name, "replaced by new diff")

    local is_new_file = vim.fn.filereadable(old_file_path) ~= 1

    if not is_new_file and is_buffer_dirty(old_file_path) then
      rpc_error(
        -32000,
        "Cannot create diff: file has unsaved changes",
        "Please save (:w) or discard (:e!) changes to " .. old_file_path .. " before creating diff"
      )
    end

    local file_buf, win = find_or_open(old_file_path)
    vim.api.nvim_set_current_win(win)

    local old_lines = vim.api.nvim_buf_get_lines(file_buf, 0, -1, false)
    local old_content = table.concat(old_lines, "\n")
    if #old_lines > 0 then
      old_content = old_content .. "\n"
    end

    local hunks = vim.diff(old_content, new_file_contents, {
      result_type = "indices",
      algorithm = "histogram",
    })

    local original_buftype = vim.api.nvim_get_option_value("buftype", { buf = file_buf })
    local ns = vim.api.nvim_create_namespace("claudediff/" .. tab_name)
    local autocmd_ids = {}
    local wiping = false

    -- Teardown runs from the resolution_callback, so it fires exactly once
    -- regardless of who triggered resolution (:w, buffer close, Claude prompt,
    -- upstream forced-cleanup, etc.).
    local function teardown(accepted)
      clear_diff_ui(file_buf, ns, autocmd_ids, original_buftype)
      if wiping then
        return
      end
      if accepted then
        pcall(vim.api.nvim_set_option_value, "modified", false, { buf = file_buf })
      else
        restore_buffer(file_buf, is_new_file)
      end
      -- Claude may write the file after resolving (common for external accept).
      -- checktime silently reloads if disk moved on the same tick; otherwise
      -- nvim's autoread picks it up on the next BufEnter/FocusGained.
      pcall(vim.api.nvim_set_option_value, "autoread", true, { buf = file_buf })
      vim.schedule(function()
        if vim.api.nvim_buf_is_valid(file_buf) then
          pcall(vim.api.nvim_buf_call, file_buf, function()
            vim.cmd("silent! checktime")
          end)
        end
      end)
    end

    -- Apply content + install handlers atomically. On failure, unwind so we never
    -- leave the user's buffer in a half-patched state (acwrite without handlers,
    -- partial extmarks, etc.).
    local setup_ok, setup_err = pcall(function()
      vim.api.nvim_buf_set_lines(file_buf, 0, -1, false, lines_for_set(new_file_contents))
      -- acwrite so `:w` hits our BufWriteCmd — we do NOT touch disk; Claude does.
      vim.api.nvim_set_option_value("buftype", "acwrite", { buf = file_buf })

      if type(hunks) == "table" then
        render_overlay(file_buf, ns, old_lines, hunks)
      end

      local group = vim.api.nvim_create_augroup("claudediff/" .. tab_name, { clear = true })
      table.insert(
        autocmd_ids,
        vim.api.nvim_create_autocmd("BufWriteCmd", {
          group = group,
          buffer = file_buf,
          callback = function()
            pcall(diff._resolve_diff_as_saved, tab_name, file_buf)
          end,
        })
      )
      table.insert(
        autocmd_ids,
        vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
          group = group,
          buffer = file_buf,
          callback = function()
            wiping = true
            pcall(diff._resolve_diff_as_rejected, tab_name)
          end,
        })
      )

      diff._register_diff_state(tab_name, {
        old_file_path = old_file_path,
        new_file_path = new_file_path,
        new_file_contents = new_file_contents,
        original_tab_number = vim.api.nvim_get_current_tabpage(),
        autocmd_ids = autocmd_ids,
        created_at = vim.fn.localtime(),
        status = "pending",
        resolution_callback = make_resolution_callback(co, teardown),
        is_new_file = is_new_file,
      })
    end)

    if not setup_ok then
      clear_diff_ui(file_buf, ns, autocmd_ids, original_buftype)
      restore_buffer(file_buf, is_new_file)
      if type(setup_err) == "table" then
        error(setup_err)
      end
      rpc_error(-32000, "Diff setup failed", tostring(setup_err))
    end

    return coroutine.yield()
  end
end

return M
