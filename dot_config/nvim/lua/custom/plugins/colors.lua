return {
  'tanvirtin/monokai.nvim',
  priority = 1000,
  init = function()
    vim.cmd.colorscheme 'monokai_soda'
    vim.cmd.hi 'Comment gui=none'
  end,
}
