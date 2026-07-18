return {
  'mrcjkb/rustaceanvim',
  version = '^9',
  ft = { 'rust' },
  init = function()
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    local ok, cmp_nvim_lsp = pcall(require, 'cmp_nvim_lsp')
    if ok then
      capabilities = vim.tbl_deep_extend('force', capabilities, cmp_nvim_lsp.default_capabilities())
    end

    local server = {
      capabilities = capabilities,
      flags = {
        -- Batch text change notifications to avoid tight didChange loops.
        debounce_text_changes = 300,
      },
      settings = function(_root_dir, default_settings)
        local settings = vim.deepcopy(default_settings or {})
        local rustfmt = vim.fn.exepath 'rustfmt'
        if rustfmt ~= '' then
          settings['rust-analyzer'] = settings['rust-analyzer'] or {}
          settings['rust-analyzer'].rustfmt = settings['rust-analyzer'].rustfmt or {}
          settings['rust-analyzer'].rustfmt.overrideCommand = { rustfmt }
        end

        return settings
      end,
    }
    local function lspmux_running()
      if vim.fn.executable 'lspmux' ~= 1 then
        return false
      end
      vim.fn.system { 'lspmux', 'status' }
      return vim.v.shell_error == 0
    end

    -- Opt-in only: lspmux can add extra latency for didChange-heavy buffers.
    if vim.g.rust_use_lspmux == true and lspmux_running() then
      server.cmd = { 'lspmux', 'client', '--server-path', 'rust-analyzer' }
    end

    vim.g.rustaceanvim = {
      server = server,
    }
  end,
}
