local M = {}

M.is_windows = vim.fn.has 'win32' == 1 or vim.fn.has 'win64' == 1
M.is_wsl = vim.fn.has 'wsl' == 1
M.is_mac = vim.uv.os_uname().sysname == 'Darwin'
M.is_linux = not M.is_windows and not M.is_mac
M.is_remote = vim.env.SSH_TTY ~= nil or vim.env.SSH_CONNECTION ~= nil

function M.path_sep()
  return M.is_windows and ';' or ':'
end

function M.joinpath(...)
  return vim.fs.joinpath(...)
end

function M.executable(cmd)
  return vim.fn.executable(cmd) == 1
end

function M.has_native_clipboard()
  if M.is_mac or M.is_windows then
    return true
  end

  return M.executable 'wl-copy' and M.executable 'wl-paste'
    or M.executable 'xclip'
    or M.executable 'xsel'
    or M.executable 'lemonade'
    or M.executable 'doitclient'
    or M.executable 'win32yank.exe'
    or M.executable 'pbcopy'
end

return M
