return {
  {
    'hrsh7th/nvim-cmp',
    event = 'InsertEnter',
    dependencies = {
      'hrsh7th/cmp-nvim-lsp',
      'hrsh7th/cmp-path',
      'saadparwaiz1/cmp_luasnip',
      'lukas-reineke/cmp-under-comparator',
      'jmbuhr/otter.nvim',
      {
        'L3MON4D3/LuaSnip',
        build = (vim.fn.has 'win32' == 1 or vim.fn.executable 'make' == 0) and nil or 'make install_jsregexp',
        dependencies = {
          {
            'rafamadriz/friendly-snippets',
            config = function()
              require('luasnip.loaders.from_vscode').lazy_load()
            end,
          },
        },
      },
    },
    config = function()
      local cmp = require 'cmp'
      local under_comparator = require('cmp-under-comparator').under
      local luasnip = require 'luasnip'
      luasnip.config.setup {}

      local function snip_next()
        if luasnip.expand_or_locally_jumpable() then
          luasnip.expand_or_jump()
        end
      end

      local function snip_prev()
        if luasnip.locally_jumpable(-1) then
          luasnip.jump(-1)
        end
      end

      cmp.setup {
        completion = { completeopt = 'menu,menuone,noinsert' },
        performance = {
          -- Avoid long waits when one source (e.g. language server) is slow.
          fetching_timeout = 500,
        },
        snippet = {
          expand = function(args)
            luasnip.lsp_expand(args.body)
          end,
        },
        mapping = cmp.mapping.preset.insert {
          ['<C-n>'] = cmp.mapping.select_next_item(),
          ['<C-p>'] = cmp.mapping.select_prev_item(),
          ['<C-b>'] = cmp.mapping.scroll_docs(-4),
          ['<C-f>'] = cmp.mapping.scroll_docs(4),
          ['<C-Space>'] = cmp.mapping.complete(),
          ['<CR>'] = cmp.mapping.confirm { select = true },
          ['<C-l>'] = cmp.mapping(snip_next, { 'i', 's' }),
          ['<C-h>'] = cmp.mapping(snip_prev, { 'i', 's' }),
        },
        sorting = {
          comparators = {
            cmp.config.compare.offset,
            cmp.config.compare.exact,
            cmp.config.compare.score,
            under_comparator,
            cmp.config.compare.kind,
            cmp.config.compare.sort_text,
            cmp.config.compare.length,
            cmp.config.compare.order,
          },
        },
        sources = cmp.config.sources {
          { name = 'nvim_lsp' },
          { name = 'luasnip' },
          { name = 'path' },
          { name = 'otter' },
        },
      }

      cmp.setup.filetype('rust', {
        sources = cmp.config.sources {
          { name = 'nvim_lsp', keyword_length = 0 },
          { name = 'luasnip' },
          { name = 'path' },
          { name = 'otter' },
        },
      })
    end,
  },
}
