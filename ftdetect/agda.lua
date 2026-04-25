vim.api.nvim_create_autocmd({ "BufRead", "BufNewFile" }, {
  pattern = { "*.agda", "*.lagda" },
  callback = function()
    vim.bo.filetype = "agda"
  end,
})
