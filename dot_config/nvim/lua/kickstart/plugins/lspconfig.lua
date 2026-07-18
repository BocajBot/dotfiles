return {
  { -- LSP Configuration & Plugins
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile' },
    cmd = { 'LspInfo', 'LspStart', 'LspStop', 'LspRestart', 'LspInstall', 'LspUninstall', 'Mason', 'MasonInstall', 'MasonUpdate' },
    dependencies = {
      { 'williamboman/mason.nvim', config = true }, -- NOTE: Must be loaded before dependants
      'williamboman/mason-lspconfig.nvim',
      'WhoIsSethDaniel/mason-tool-installer.nvim',

      -- NOTE: `opts = {}` is the same as calling `require('fidget').setup({})`
      { 'j-hui/fidget.nvim', opts = {} },

      {
        'folke/lazydev.nvim',
        ft = 'lua',
        opts = {
          library = {
            { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
          },
        },
      },
    },
    config = function()
      vim.api.nvim_create_autocmd('LspAttach', {
        group = vim.api.nvim_create_augroup('kickstart-lsp-attach', { clear = true }),
        callback = function(event)
          local map = function(keys, func, desc)
            vim.keymap.set('n', keys, func, { buf = event.buf, desc = 'LSP: ' .. desc })
          end

          local client = vim.lsp.get_client_by_id(event.data.client_id)
          require('keymaps').lsp(map, client)

          -- If built-in LSP completion was enabled elsewhere, turn it off for
          -- rust-analyzer so completion requests stay on explicit/manual paths.
          if client and client.name == 'rust-analyzer' and vim.lsp.completion then
            pcall(vim.lsp.completion.enable, false, client.id, event.buf)
          end

          if client and client.server_capabilities.documentHighlightProvider and client.name ~= 'rust-analyzer' then
            local highlight_augroup = vim.api.nvim_create_augroup('kickstart-lsp-highlight', { clear = false })
            vim.api.nvim_create_autocmd({ 'CursorHold', 'CursorHoldI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.document_highlight,
            })

            vim.api.nvim_create_autocmd({ 'CursorMoved', 'CursorMovedI' }, {
              buffer = event.buf,
              group = highlight_augroup,
              callback = vim.lsp.buf.clear_references,
            })

            vim.api.nvim_create_autocmd('LspDetach', {
              group = vim.api.nvim_create_augroup('kickstart-lsp-detach', { clear = true }),
              callback = function(event2)
                vim.lsp.buf.clear_references()
                vim.api.nvim_clear_autocmds { group = 'kickstart-lsp-highlight', buffer = event2.buf }
              end,
            })
          end
        end,
      })

      local capabilities = vim.lsp.protocol.make_client_capabilities()
      capabilities = vim.tbl_deep_extend('force', capabilities, require('cmp_nvim_lsp').default_capabilities())
      vim.lsp.config('*', {
        capabilities = capabilities,
      })

      local servers = {
        lua_ls = {
          settings = {
            Lua = { completion = { callSnippet = 'Replace' } },
          },
        },

        bashls = {
          filetypes = { 'sh', 'bash', 'zsh' },
          settings = {
            bashIde = {
              -- optional but useful: include zsh-ish names for workspace indexing
              globPattern = '*@(.sh|.inc|.bash|.command|.zsh|zshrc|.zshrc|zsh_*|.zsh_*)',
            },
          },
        },
      }

      for server_name, server in pairs(servers) do
        vim.lsp.config(server_name, server)
      end

      local ensure_installed = vim.tbl_keys(servers or {})
      vim.list_extend(ensure_installed, {
        'stylua', -- Used to format Lua code
        'rust_analyzer',
        'pylsp',
        'bashls',
        'html',
        'clangd',
        'jsonls',
        'yamlls',
        'quick-lint-js',
      })
      require('mason-tool-installer').setup { ensure_installed = ensure_installed }

      require('mason-lspconfig').setup {
        automatic_enable = {
          exclude = { 'rust_analyzer' },
        },
      }
    end,
  },
}
-- vim: ts=2 sts=2 sw=2 et
