local M = {}

local function apply_patch(notify_on_fail)
  local ok, diff = pcall(require, "claudecode.diff")
  if not ok or type(diff) ~= "table" then
    if notify_on_fail then
      vim.notify("claudediff.nvim: claudecode.diff not found", vim.log.levels.WARN)
    end
    return false
  end
  diff.open_diff_blocking = require("claudediff.renderer").make_open_diff_blocking(diff)
  return true
end

function M.setup()
  if apply_patch(false) then
    return
  end
  vim.api.nvim_create_autocmd("VimEnter", {
    once = true,
    callback = function()
      vim.defer_fn(function()
        apply_patch(true)
      end, 100)
    end,
  })
end

return M
