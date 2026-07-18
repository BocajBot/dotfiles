local M = {}

local function jump_diagnostic(count)
  return function()
    vim.diagnostic.jump {
      count = count,
      on_jump = function(_, bufnr)
        vim.diagnostic.open_float {
          bufnr = bufnr,
          scope = 'cursor',
          focus = false,
        }
      end,
    }
  end
end

local function telescope_builtin(name)
  return function()
    require('telescope.builtin')[name]()
  end
end

local function telescope_dropdown()
  require('telescope.builtin').current_buffer_fuzzy_find(require('telescope.themes').get_dropdown {
    winblend = 10,
    previewer = false,
  })
end

local function telescope_live_grep_open_files()
  require('telescope.builtin').live_grep {
    grep_open_files = true,
    prompt_title = 'Live Grep in Open Files',
  }
end

local function telescope_find_config()
  require('telescope.builtin').find_files { cwd = vim.fn.stdpath 'config' }
end

-- [[ Basic Keymaps ]]
--  See `:help vim.keymap.set()`
function M.setup()
  -- Path Viewer
  vim.keymap.set('n', '<leader>pv', vim.cmd.Ex)

  -- Paste over text without copying selected
  vim.keymap.set('x', '<leader>p', [["_dP]])

  -- NOTE: Yanks to system clipboard
  vim.keymap.set({ 'n', 'v' }, '<leader>y', [["+y]])
  vim.keymap.set('n', '<leader>Y', [["+Y]])

  -- Delete without replacing the current yank.
  vim.keymap.set({ 'n', 'v' }, '<leader>x', [["_d]], { desc = 'Delete without yank' })

  -- Ctrl + c to exit Insert mode
  vim.keymap.set('i', '<C-c>', '<Esc>')

  -- Remove Q from normal mode
  vim.keymap.set('n', 'Q', '<nop>')

  -- Set highlight on search, but clear on pressing <Esc> in normal mode
  vim.opt.hlsearch = true
  vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

  -- [F]ind and [R]eplace
  vim.keymap.set('n', '<leader>fr', ':%s@<C-r><C-w>@<C-r><C-w>@gc<Left><Left><Left>', { desc = '[F]ind and [R]eplace word under cursor', silent = false })

  -- Diagnostic keymaps
  vim.keymap.set('n', '[d', jump_diagnostic(-1), { desc = 'Go to previous [D]iagnostic message' })
  vim.keymap.set('n', ']d', jump_diagnostic(1), { desc = 'Go to next [D]iagnostic message' })
  vim.keymap.set('n', '<leader>e', vim.diagnostic.open_float, { desc = 'Show diagnostic [E]rror messages' })
  vim.keymap.set('n', '<leader>q', vim.diagnostic.setloclist, { desc = 'Open diagnostic [Q]uickfix list' })

  -- Exit terminal mode in the builtin terminal with a shortcut that is a bit easier
  -- for people to discover. Otherwise, you normally need to press <C-\\><C-n>, which
  -- is not what someone will guess without a bit more experience.
  --
  -- NOTE: This won't work in all terminal emulators/tmux/etc. Try your own mapping
  -- or just use <C-\\><C-n> to exit terminal mode
  vim.keymap.set('t', '<Esc><Esc>', '<C-\\><C-n>', { desc = 'Exit terminal mode' })

  -- TIP: Disable arrow keys in normal mode
  -- vim.keymap.set('n', '<left>', '<cmd>echo "Use h to move!!"<CR>')
  -- vim.keymap.set('n', '<right>', '<cmd>echo "Use l to move!!"<CR>')
  -- vim.keymap.set('n', '<up>', '<cmd>echo "Use k to move!!"<CR>')
  -- vim.keymap.set('n', '<down>', '<cmd>echo "Use j to move!!"<CR>')

  -- Keybinds to make split navigation easier.
  --  Use CTRL+<hjkl> to switch between windows
  --
  --  See `:help wincmd` for a list of all window commands
  vim.keymap.set('n', '<C-h>', '<C-w><C-h>', { desc = 'Move focus to the left window' })
  vim.keymap.set('n', '<C-l>', '<C-w><C-l>', { desc = 'Move focus to the right window' })
  vim.keymap.set('n', '<C-j>', '<C-w><C-j>', { desc = 'Move focus to the lower window' })
  vim.keymap.set('n', '<C-k>', '<C-w><C-k>', { desc = 'Move focus to the upper window' })

  M.telescope()

  -- [[ Basic Autocommands ]]
  --  See `:help lua-guide-autocommands`

  -- Highlight when yanking (copying) text
  --  Try it with `yap` in normal mode
  --  See `:help vim.highlight.on_yank()`
  vim.api.nvim_create_autocmd('TextYankPost', {
    desc = 'Highlight when yanking (copying) text',
    group = vim.api.nvim_create_augroup('kickstart-highlight-yank', { clear = true }),
    callback = function()
      local hl = vim.hl or vim.highlight
      hl.on_yank()
    end,
  })
end

function M.telescope()
  vim.keymap.set('n', '<leader>sh', telescope_builtin 'help_tags', { desc = '[S]earch [H]elp' })
  vim.keymap.set('n', '<leader>sk', telescope_builtin 'keymaps', { desc = '[S]earch [K]eymaps' })
  vim.keymap.set('n', '<leader>sf', telescope_builtin 'find_files', { desc = '[S]earch [F]iles' })
  vim.keymap.set('n', '<leader>ss', telescope_builtin 'builtin', { desc = '[S]earch [S]elect Telescope' })
  vim.keymap.set('n', '<leader>sw', telescope_builtin 'grep_string', { desc = '[S]earch current [W]ord' })
  vim.keymap.set('n', '<leader>sg', telescope_builtin 'live_grep', { desc = '[S]earch by [G]rep' })
  vim.keymap.set('n', '<leader>sd', telescope_builtin 'diagnostics', { desc = '[S]earch [D]iagnostics' })
  vim.keymap.set('n', '<leader>sr', telescope_builtin 'resume', { desc = '[S]earch [R]esume' })
  vim.keymap.set('n', '<leader>s.', telescope_builtin 'oldfiles', { desc = '[S]earch Recent Files ("." for repeat)' })
  vim.keymap.set('n', '<leader><leader>', telescope_builtin 'buffers', { desc = '[ ] Find existing buffers' })
  vim.keymap.set('n', '<leader>/', telescope_dropdown, { desc = '[/] Fuzzily search in current buffer' })
  vim.keymap.set('n', '<leader>s/', telescope_live_grep_open_files, { desc = '[S]earch [/] in Open Files' })
  vim.keymap.set('n', '<leader>sn', telescope_find_config, { desc = '[S]earch [N]eovim files' })
end

function M.gitsigns(map, gitsigns)
  -- Navigation
  map('n', ']c', function()
    if vim.wo.diff then
      vim.cmd.normal { ']c', bang = true }
    else
      gitsigns.nav_hunk 'next'
    end
  end, { desc = 'Jump to next git [c]hange' })

  map('n', '[c', function()
    if vim.wo.diff then
      vim.cmd.normal { '[c', bang = true }
    else
      gitsigns.nav_hunk 'prev'
    end
  end, { desc = 'Jump to previous git [c]hange' })

  -- Actions
  -- visual mode
  map('v', '<leader>hs', function()
    gitsigns.stage_hunk { vim.fn.line '.', vim.fn.line 'v' }
  end, { desc = 'stage git hunk' })
  map('v', '<leader>hr', function()
    gitsigns.reset_hunk { vim.fn.line '.', vim.fn.line 'v' }
  end, { desc = 'reset git hunk' })
  -- normal mode
  map('n', '<leader>hs', gitsigns.stage_hunk, { desc = 'git [s]tage hunk' })
  map('n', '<leader>hr', gitsigns.reset_hunk, { desc = 'git [r]eset hunk' })
  map('n', '<leader>hS', gitsigns.stage_buffer, { desc = 'git [S]tage buffer' })
  map('n', '<leader>hu', gitsigns.undo_stage_hunk, { desc = 'git [u]ndo stage hunk' })
  map('n', '<leader>hR', gitsigns.reset_buffer, { desc = 'git [R]eset buffer' })
  map('n', '<leader>hp', gitsigns.preview_hunk, { desc = 'git [p]review hunk' })
  map('n', '<leader>hb', gitsigns.blame_line, { desc = 'git [b]lame line' })
  map('n', '<leader>hd', gitsigns.diffthis, { desc = 'git [d]iff against index' })
  map('n', '<leader>hD', function()
    gitsigns.diffthis '@'
  end, { desc = 'git [D]iff against last commit' })
  -- Toggles
  map('n', '<leader>tb', gitsigns.toggle_current_line_blame, { desc = '[T]oggle git show [b]lame line' })
  map('n', '<leader>tD', gitsigns.toggle_deleted, { desc = '[T]oggle git show [D]eleted' })
end

function M.dap(dap, dapui)
  vim.keymap.set('n', '<F5>', dap.continue, { desc = 'Debug: Start/Continue' })
  vim.keymap.set('n', '<F1>', dap.step_into, { desc = 'Debug: Step Into' })
  vim.keymap.set('n', '<F2>', dap.step_over, { desc = 'Debug: Step Over' })
  vim.keymap.set('n', '<F3>', dap.step_out, { desc = 'Debug: Step Out' })
  vim.keymap.set('n', '<leader>b', dap.toggle_breakpoint, { desc = 'Debug: Toggle Breakpoint' })
  vim.keymap.set('n', '<leader>B', function()
    dap.set_breakpoint(vim.fn.input 'Breakpoint condition: ')
  end, { desc = 'Debug: Set Breakpoint' })
  vim.keymap.set('n', '<F7>', dapui.toggle, { desc = 'Debug: See last session result.' })
end

function M.lsp(map, client)
  map('gd', telescope_builtin 'lsp_definitions', '[G]oto [D]efinition')
  map('gr', telescope_builtin 'lsp_references', '[G]oto [R]eferences')
  map('gI', telescope_builtin 'lsp_implementations', '[G]oto [I]mplementation')
  map('<leader>D', telescope_builtin 'lsp_type_definitions', 'Type [D]efinition')
  map('<leader>ds', telescope_builtin 'lsp_document_symbols', '[D]ocument [S]ymbols')
  map('<leader>ws', telescope_builtin 'lsp_dynamic_workspace_symbols', '[W]orkspace [S]ymbols')
  map('<leader>rn', vim.lsp.buf.rename, '[R]e[n]ame')
  map('<leader>ca', vim.lsp.buf.code_action, '[C]ode [A]ction')
  map('K', vim.lsp.buf.hover, 'Hover Documentation')
  map('gD', vim.lsp.buf.declaration, '[G]oto [D]eclaration')

  if client and client.server_capabilities.inlayHintProvider and vim.lsp.inlay_hint then
    map('<leader>th', function()
      vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled())
    end, '[T]oggle Inlay [H]ints')
  end
end

return M
