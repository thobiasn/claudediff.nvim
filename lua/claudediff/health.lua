local M = {}

local REQUIRED = {
  "open_diff_blocking",
  "_register_diff_state",
  "_resolve_diff_as_saved",
  "_resolve_diff_as_rejected",
  "_cleanup_diff_state",
}

function M.check()
  vim.health.start("claudediff.nvim")

  local ok, diff = pcall(require, "claudecode.diff")
  if not ok or type(diff) ~= "table" then
    vim.health.error(
      "claudecode.diff not loadable",
      "Install coder/claudecode.nvim and ensure it's on the runtimepath."
    )
    return
  end
  vim.health.ok("claudecode.diff loaded")

  local missing = {}
  for _, name in ipairs(REQUIRED) do
    if type(diff[name]) ~= "function" then
      table.insert(missing, name)
    end
  end
  if #missing == 0 then
    vim.health.ok("upstream API symbols present")
  else
    vim.health.error(
      "upstream API drift — missing: " .. table.concat(missing, ", "),
      "Pin to a claudecode.nvim version where these symbols exist, or open an issue."
    )
  end

end

return M
