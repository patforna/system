-- Bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({ "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git", "--branch=stable", lazypath })
end
vim.opt.rtp:prepend(lazypath)

-- Leader (must be before lazy)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Options
vim.opt.number = true
vim.opt.relativenumber = false
vim.opt.signcolumn = "yes"
vim.opt.cursorline = true
vim.opt.termguicolors = true
vim.opt.expandtab = true
vim.opt.shiftwidth = 4
vim.opt.tabstop = 4
vim.opt.smartindent = true
vim.opt.wrap = true
vim.opt.ignorecase = true
vim.opt.smartcase = true
vim.opt.splitright = true
vim.opt.splitbelow = true
vim.opt.clipboard = "unnamedplus"
vim.opt.scrolloff = 8
vim.opt.updatetime = 250

-- Plugins
require("lazy").setup({
  { "olimorris/onedarkpro.nvim", priority = 1000,
    config = function() vim.cmd.colorscheme("onedark") end },

  { "nvim-treesitter/nvim-treesitter", build = ":TSUpdate",
    config = function()
      require("nvim-treesitter.configs").setup({
        ensure_installed = { "python", "lua", "toml", "yaml", "json", "sql", "markdown", "bash", "diff", "gitcommit" },
        highlight = { enable = true },
      })
    end },

  { "ibhagwan/fzf-lua", dependencies = { "nvim-tree/nvim-web-devicons" },
    config = function()
      local fzf = require("fzf-lua")
      vim.keymap.set("n", "<leader>f", fzf.files, { desc = "Find files" })
      vim.keymap.set("n", "<leader>g", fzf.live_grep, { desc = "Live grep" })
      vim.keymap.set("n", "<leader>b", fzf.buffers, { desc = "Buffers" })
      vim.keymap.set("n", "<leader>h", fzf.help_tags, { desc = "Help tags" })
    end },

  { "lewis6991/gitsigns.nvim",
    config = function() require("gitsigns").setup() end },

  { "numToStr/Comment.nvim",
    config = function() require("Comment").setup() end },

  { "echasnovski/mini.surround", version = false,
    config = function() require("mini.surround").setup() end },

  { "echasnovski/mini.pairs", version = false,
    config = function() require("mini.pairs").setup() end },

  { "stevearc/conform.nvim",
    config = function()
      require("conform").setup({
        formatters_by_ft = {
          python = { "ruff_format" },
          lua = { "stylua" },
        },
        format_on_save = { timeout_ms = 500, lsp_format = "fallback" },
      })
    end },
})
