return {
  filetypes = { 'sh', 'bash', 'zsh' },

  -- Force activation for dotfiles outside a repo by always providing a root.
  root_dir = function(bufnr, on_dir)
    local fname = vim.api.nvim_buf_get_name(bufnr)
    on_dir(vim.fs.root(fname, '.git') or vim.fn.expand '~')
  end,
}
