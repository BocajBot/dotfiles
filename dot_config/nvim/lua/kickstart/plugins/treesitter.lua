return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    build = ':TSUpdate',
    lazy = false,

    opts = {
      install_dir = vim.fn.stdpath 'data' .. '/site',

      ensure_installed = {
        'bash',
        'c',
        'diff',
        'html',
        'javascript',
        'lua',
        'luadoc',
        'markdown',
        'markdown_inline',
        'vim',
        'vimdoc',
      },
    },

    config = function(_, opts)
      require('nvim-treesitter').setup(opts)

      vim.api.nvim_create_autocmd('FileType', {
        callback = function(args)
          pcall(vim.treesitter.start, args.buf)
        end,
      })
    end,
  },
}
