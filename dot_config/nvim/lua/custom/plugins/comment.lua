return {
  'folke/ts-comments.nvim',
  enabled = vim.fn.has 'nvim-0.10' == 1,
  lazy = false,
  opts = {
    lang = {
      lua = { '-- %s', '--[[ %s ]]' },
      luau = { '-- %s', '--[[ %s ]]' },
      metalua = { '-- %s', '--[[ %s ]]' },
      teal = { '-- %s', '--[[ %s ]]' },
    },
  },
  config = function(_, opts)
    require('ts-comments').setup(opts)

    local comments = require 'ts-comments.comments'
    local config = require 'ts-comments.config'

    local function parse_commentstring(cs)
      if type(cs) ~= 'string' then
        return
      end

      local left, right = cs:match '^(.-)%%s(.-)$'
      if not left then
        return
      end

      return left, right
    end

    local function collect_patterns(spec, acc)
      if type(spec) == 'string' then
        acc[#acc + 1] = spec
      elseif vim.islist(spec) then
        for _, item in ipairs(spec) do
          collect_patterns(item, acc)
        end
      elseif type(spec) == 'table' then
        for _, item in pairs(spec) do
          collect_patterns(item, acc)
        end
      end
    end

    local function fallback_patterns(ft)
      local patterns = {}
      local lang = vim.treesitter.language.get_lang(ft) or ft

      collect_patterns(config.options.lang[lang], patterns)
      if type(vim.bo.commentstring) == 'string' and vim.bo.commentstring ~= '' then
        patterns[#patterns + 1] = vim.bo.commentstring
      end

      return patterns
    end

    local function get_comment_parts(kind)
      local ft = vim.bo.filetype
      local fallback
      local resolved = {}
      local ok, patterns = pcall(comments.resolve, ft)

      if ok and type(patterns) == 'table' then
        resolved = patterns
      else
        resolved = fallback_patterns(ft)
      end

      for _, cs in ipairs(resolved) do
        local left, right = parse_commentstring(cs)
        if left then
          fallback = fallback or { left, right }
          local is_block = right ~= ''

          if kind == 'line' then
            return left, right
          end

          if kind == 'block' and is_block then
            return left, right
          end
        end
      end

      if kind == 'line' and fallback then
        return fallback[1], fallback[2]
      end
    end

    local function notify_missing(kind)
      local target = kind == 'block' and 'block comments' or 'commentstring'
      local filetype = vim.bo.filetype ~= '' and vim.bo.filetype or 'none'
      vim.notify(('No %s available for %s'):format(target, filetype), vim.log.levels.WARN)
    end

    local function line_length(row)
      return #(vim.api.nvim_buf_get_lines(0, row - 1, row, false)[1] or '')
    end

    local function line_count()
      return vim.api.nvim_buf_line_count(0)
    end

    local function set_cursor_and_insert(row, col)
      vim.api.nvim_win_set_cursor(0, { row, col })
      vim.cmd.startinsert()
    end

    local function insert_comment_line(offset)
      local left, right = get_comment_parts 'line'
      if not left then
        notify_missing 'line'
        return
      end

      local row = vim.api.nvim_win_get_cursor(0)[1]
      local current = vim.api.nvim_get_current_line()
      local indent = current:match '^%s*' or ''
      local text = indent .. left .. right
      local insert_at = offset > 0 and row or row - 1
      local cursor_row = offset > 0 and row + 1 or row

      vim.api.nvim_buf_set_lines(0, insert_at, insert_at, false, { text })
      set_cursor_and_insert(cursor_row, #indent + #left)
    end

    local function insert_comment_eol()
      local left, right = get_comment_parts 'line'
      if not left then
        notify_missing 'line'
        return
      end

      local row = vim.api.nvim_win_get_cursor(0)[1]
      local line = vim.api.nvim_get_current_line()
      local spacer = line:match '^%s*$' and '' or ' '

      vim.api.nvim_set_current_line(line .. spacer .. left .. right)
      set_cursor_and_insert(row, #line + #spacer + #left)
    end

    local function normalize_range(start_row, start_col, end_row, end_col)
      if start_row > end_row or (start_row == end_row and start_col > end_col) then
        start_row, end_row = end_row, start_row
        start_col, end_col = end_col, start_col
      end

      return {
        start_row = start_row,
        start_col = start_col,
        end_row = end_row,
        end_col = end_col,
        mode = 'char',
      }
    end

    local function toggle_block_selection(lines, range, left, right)
      for index, line in ipairs(lines) do
        local before = line:sub(1, range.start_col)
        local selected = line:sub(range.start_col + 1, range.end_col + 1)
        local after = line:sub(range.end_col + 2)
        local is_commented = selected:sub(1, #left) == left and selected:sub(-#right) == right

        if is_commented then
          selected = selected:sub(#left + 1, #selected - #right)
        else
          selected = left .. selected .. right
        end

        lines[index] = before .. selected .. after
      end
    end

    local function toggle_block(range)
      local left, right = get_comment_parts 'block'
      if not left or right == '' then
        notify_missing 'block'
        return
      end

      local lines = vim.api.nvim_buf_get_lines(0, range.start_row - 1, range.end_row, false)
      if vim.tbl_isempty(lines) then
        return
      end

      if range.mode == 'block' then
        toggle_block_selection(lines, range, left, right)
      elseif #lines == 1 then
        local line = lines[1]
        local before = line:sub(1, range.start_col)
        local selected = line:sub(range.start_col + 1, range.end_col + 1)
        local after = line:sub(range.end_col + 2)
        local is_commented = selected:sub(1, #left) == left and selected:sub(-#right) == right

        if is_commented then
          selected = selected:sub(#left + 1, #selected - #right)
        else
          selected = left .. selected .. right
        end

        lines[1] = before .. selected .. after
      else
        local first = lines[1]
        local last = lines[#lines]
        local before = first:sub(1, range.start_col)
        local first_selected = first:sub(range.start_col + 1)
        local last_selected = last:sub(1, range.end_col + 1)
        local after = last:sub(range.end_col + 2)
        local is_commented = first_selected:sub(1, #left) == left and last_selected:sub(-#right) == right

        if is_commented then
          lines[1] = before .. first_selected:sub(#left + 1)
          lines[#lines] = last_selected:sub(1, #last_selected - #right) .. after
        else
          lines[1] = before .. left .. first_selected
          lines[#lines] = last_selected .. right .. after
        end
      end

      vim.api.nvim_buf_set_lines(0, range.start_row - 1, range.end_row, false, lines)
    end

    local function current_block_range(count)
      local row = vim.api.nvim_win_get_cursor(0)[1]
      local last_row = math.min(row + count - 1, line_count())
      local end_len = line_length(last_row)
      local range = normalize_range(row, 0, last_row, math.max(end_len - 1, 0))
      range.mode = 'line'
      return range
    end

    local function visual_block_range()
      local start = vim.api.nvim_buf_get_mark(0, '<')
      local finish = vim.api.nvim_buf_get_mark(0, '>')
      local mode = vim.fn.visualmode()

      if mode == '\22' then
        local range = normalize_range(start[1], start[2], finish[1], finish[2])
        range.mode = 'block'
        return range
      end

      if mode == 'V' then
        local end_len = line_length(finish[1])
        local range = normalize_range(start[1], 0, finish[1], math.max(end_len - 1, 0))
        range.mode = 'line'
        return range
      end

      return normalize_range(start[1], start[2], finish[1], finish[2])
    end

    local function operator_block_range(mode)
      local start = vim.api.nvim_buf_get_mark(0, '[')
      local finish = vim.api.nvim_buf_get_mark(0, ']')

      if mode == 'block' then
        local range = normalize_range(start[1], start[2], finish[1], finish[2])
        range.mode = 'block'
        return range
      end

      if mode == 'line' then
        local end_len = line_length(finish[1])
        local range = normalize_range(start[1], 0, finish[1], math.max(end_len - 1, 0))
        range.mode = 'line'
        return range
      end

      return normalize_range(start[1], start[2], finish[1], finish[2])
    end

    _G.CodexBlockCommentOperator = function(mode)
      toggle_block(operator_block_range(mode))
    end

    local function start_block_operator()
      vim.go.operatorfunc = 'v:lua.CodexBlockCommentOperator'
      return 'g@'
    end

    local function remap(mode, lhs, rhs, desc)
      vim.keymap.set(mode, lhs, rhs, { remap = true, desc = desc })
    end

    remap('n', '<leader>cc', 'gcc', 'Comment toggle current line')
    remap('x', '<leader>cc', 'gc', 'Comment toggle selection')
    for _, lhs in ipairs { '<C-_>', '<C-/>' } do
      remap('n', lhs, 'gcc', 'Comment toggle current line')
      remap('x', lhs, 'gc', 'Comment toggle selection')
    end

    vim.keymap.set('n', '<leader>cb', function()
      toggle_block(current_block_range(vim.v.count1))
    end, { desc = 'Comment toggle current block' })
    vim.keymap.set('x', '<leader>cb', function()
      toggle_block(visual_block_range())
    end, { desc = 'Comment toggle selected block' })
    vim.keymap.set('n', 'gb', start_block_operator, { expr = true, desc = 'Comment toggle blockwise' })
    vim.keymap.set('x', 'gb', function()
      toggle_block(visual_block_range())
    end, { desc = 'Comment toggle blockwise' })
    vim.keymap.set('n', 'gbc', function()
      toggle_block(current_block_range(vim.v.count1))
    end, { desc = 'Comment toggle current block' })

    vim.keymap.set('n', 'gco', function()
      insert_comment_line(1)
    end, { desc = 'Comment insert below' })
    vim.keymap.set('n', 'gcO', function()
      insert_comment_line(-1)
    end, { desc = 'Comment insert above' })
    vim.keymap.set('n', 'gcA', insert_comment_eol, { desc = 'Comment insert end of line' })
  end,
}
