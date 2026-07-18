return {
  'nvim-lualine/lualine.nvim',
  event = 'VeryLazy',
  dependencies = {
    { 'nvim-tree/nvim-web-devicons', enabled = vim.g.have_nerd_font },
  },
  config = function()
    local lualine = require 'lualine'
    local use_icons = vim.g.have_nerd_font

    -- Colors
    local colors = {
      bg = '#202328',
      fg = '#bbc2cf',
      yellow = '#ECBE7B',
      cyan = '#008080',
      darkblue = '#081633',
      green = '#98be65',
      orange = '#FF8800',
      violet = '#a9a1e1',
      magenta = '#c678dd',
      blue = '#51afef',
      red = '#ec5f67',
    }

    -- Conditions
    local function buffer_not_empty()
      return vim.fn.empty(vim.fn.expand '%:t') ~= 1
    end

    local function hide_in_width()
      return vim.fn.winwidth(0) > 80
    end

    -- Config
    local config = {
      options = {
        icons_enabled = use_icons,
        component_separators = '',
        section_separators = '',
        theme = {
          normal = { c = { fg = colors.fg, bg = colors.bg } },
          inactive = { c = { fg = colors.fg, bg = colors.bg } },
        },
      },
      sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_y = {},
        lualine_z = {},
        lualine_c = {},
        lualine_x = {},
      },
      inactive_sections = {
        lualine_a = {},
        lualine_b = {},
        lualine_y = {},
        lualine_z = {},
        lualine_c = {},
        lualine_x = {},
      },
    }

    -- Insert Components
    local function ins(section, component)
      table.insert(config.sections[section], component)
    end

    -- Insert Components
    ins('lualine_c', {
      function()
        return use_icons and '▊' or '|'
      end,
      color = { fg = colors.blue },
      padding = { left = 0, right = 1 },
    })
    ins('lualine_c', {
      function()
        return use_icons and '' or 'NVIM'
      end,
      color = function()
        -- auto change color according to neovims mode
        local mode_color = {
          n = colors.red,
          i = colors.green,
          v = colors.blue,
          [''] = colors.blue,
          V = colors.blue,
          c = colors.magenta,
          no = colors.red,
          s = colors.orange,
          S = colors.orange,
          [''] = colors.orange,
          ic = colors.yellow,
          R = colors.violet,
          Rv = colors.violet,
          cv = colors.red,
          ce = colors.red,
          r = colors.cyan,
          rm = colors.cyan,
          ['r?'] = colors.cyan,
          ['!'] = colors.red,
          t = colors.red,
        }
        return { fg = mode_color[vim.fn.mode()] }
      end,
      padding = { right = 1 },
    }) -- mode component
    ins('lualine_c', { 'filesize', cond = buffer_not_empty })
    ins('lualine_c', { 'filename', cond = buffer_not_empty, color = { fg = colors.magenta, gui = 'bold' } })
    ins('lualine_c', { 'location' })
    ins('lualine_c', { 'progress', color = { fg = colors.fg, gui = 'bold' } })
    ins('lualine_c', {
      function()
        return '%='
      end,
    }) -- mid section
    ins('lualine_c', {
      function()
        local msg = 'No Active Lsp'
        local buf_ft = vim.bo.filetype
        local clients = vim.lsp.get_clients { bufnr = 0 }

        if next(clients) == nil then
          return msg
        end
        for _, client in ipairs(clients) do
          local filetypes = client.config.filetypes
          if filetypes and vim.fn.index(filetypes, buf_ft) ~= -1 then
            return client.name
          end
        end
        return msg
      end,
      icon = use_icons and ' LSP:' or 'LSP:',
      color = { fg = '#ffffff', gui = 'bold' },
    }) -- LSP server name

    -- Add components right section
    ins('lualine_x', { 'o:encoding', fmt = string.upper, cond = hide_in_width, color = { fg = colors.green, gui = 'bold' } })
    ins('lualine_x', { 'fileformat', fmt = string.upper, icons_enabled = false, color = { fg = colors.green, gui = 'bold' } })
    ins('lualine_x', { 'branch', icon = use_icons and '' or 'git', color = { fg = colors.violet, gui = 'bold' } })
    ins('lualine_x', {
      'diff',
      symbols = use_icons and { added = ' ', modified = ' ', removed = ' ' } or { added = '+', modified = '~', removed = '-' },
      diff_color = { added = { fg = colors.green }, modified = { fg = colors.orange }, removed = { fg = colors.red } },
      cond = hide_in_width,
    })
    ins('lualine_x', {
      function()
        return use_icons and '▊' or '|'
      end,
      color = { fg = colors.blue },
      padding = { left = 1 },
    })

    lualine.setup(config)
  end,
}
