local M = {}

M.config = {
  keymaps = {
    accept = "<leader>ya",
    reject = "<leader>yn",
  },
}

local function apply_patch(notify_on_fail)
  local ok, diff = pcall(require, "claudecode.diff")
  if not ok or type(diff) ~= "table" then
    if notify_on_fail then
      vim.notify("claudediff.nvim: claudecode.diff not found", vim.log.levels.WARN)
    end
    return false
  end
  diff.open_diff_blocking = require("claudediff.renderer").make_open_diff_blocking(diff, M.config)
  return true
end

function M.setup(opts)
  if opts then
    M.config = vim.tbl_deep_extend("force", M.config, opts)
  end
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
