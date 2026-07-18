vim.g.mapleader = ' '
vim.g.maplocalleader = ' '

if vim.loader then
  vim.loader.enable()
end

-- Set to true if you have a Nerd Font installed and selected in the terminal
vim.g.have_nerd_font = false

-- Disable unused remote plugin providers to reduce startup checks and health noise.
vim.g.loaded_node_provider = 0
vim.g.loaded_perl_provider = 0
vim.g.loaded_python3_provider = 0
vim.g.loaded_ruby_provider = 0

-- [[ Setting options ]]
require 'options'

require('keymaps').setup()

-- [[ Install `lazy.nvim` plugin manager ]]
require 'lazy-bootstrap'

-- [[ Configure and install plugins ]]
require 'lazy-plugins'
