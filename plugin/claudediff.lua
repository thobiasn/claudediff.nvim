if vim.g.loaded_claudediff then
  return
end
vim.g.loaded_claudediff = 1

require("claudediff").setup()
