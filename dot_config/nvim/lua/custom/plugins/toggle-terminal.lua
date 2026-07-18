return {
  {
    'akinsho/toggleterm.nvim',
    cmd = 'ToggleTerm',
    keys = function()
      local platform = require 'platform'

      local function terminal_env()
        local venv = vim.b.virtual_env
        if not venv or venv == '' then
          return nil
        end

        local bindir = platform.joinpath(venv, platform.is_windows and 'Scripts' or 'bin')
        return {
          VIRTUAL_ENV = venv,
          PATH = bindir .. platform.path_sep() .. (vim.env.PATH or ''),
        }
      end

      local function toggleterm()
        local term = require('toggleterm.terminal').Terminal:new {
          env = terminal_env(),
          count = vim.v.count > 0 and vim.v.count or 1,
        }
        term:toggle()
      end
      return {
        { '<leader>tt', mode = { 'n', 't' }, toggleterm, desc = 'Toggle Terminal' },
      }
    end,
    opts = {
      open_mapping = false,
      float_opts = {
        border = 'curved',
      },
    },
  },
}
