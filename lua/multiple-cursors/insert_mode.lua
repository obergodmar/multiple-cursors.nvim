local M = {}

local common = require("multiple-cursors.common")
local virtual_cursors = require("multiple-cursors.virtual_cursors")
local move_special = require("multiple-cursors.move_special")

-- Character to insert
local char = nil

-- For executing a delete command without modifying the register
local function normal_bang_delete(cmd)
  local register_info = vim.fn.getreginfo('"')
  vim.cmd("normal! " .. cmd)
  vim.fn.setreg('"', register_info)
end

-- Delete a charater if in replace mode
local function delete_if_replace_mode(vc)
  if common.is_mode("R") then
    -- ToDo save and restore register info
    if vc.col == common.get_length_of_line(vc.lnum) then
      normal_bang_delete("x")
      common.set_cursor_to_virtual_cursor(vc)
    elseif vc.col < common.get_length_of_line(vc.lnum) then
      normal_bang_delete("x")
    end
  end
end

-- Is lnum, col before the first non-whitespace character
local function is_before_first_non_whitespace_char(lnum, col)
  local idx = vim.fn.match(vim.fn.getline(lnum), "\\S")
  if idx < 0 then
    return true
  else
    return col <= idx + 1
  end
end


-- Escape key ------------------------------------------------------------------

function M.escape()
  -- Move the cursor back
  virtual_cursors.move_normal("h", 0)
end


-- Insert text -----------------------------------------------------------------

-- Callback for InsertCharPre event
function M.insert_char_pre(event)
  -- Save the inserted character
  char = vim.v.char
end

-- Callback for the TextChangedI event
function M.text_changed_i(event)

  -- If there's a saved character
  if char then
    -- Put it to virtual cursors
    virtual_cursors.edit(function(vc)
      delete_if_replace_mode(vc)
      vim.api.nvim_put({char}, "c", false, true)
      common.set_virtual_cursor_from_cursor(vc)
    end, false)
    char = nil
  end

end


-- Backspace -------------------------------------------------------------------

-- Get the character at lnum, col
local function get_char(lnum, col)
  local l = vim.fn.getline(lnum)
  local c = string.sub(l, col - 1, col - 1)
  return c
end

-- Is the character at lnum, col a space?
local function is_space(lnum, col)
  return get_char(lnum, col) == " "
end

-- Is the character at lnum, col a tab?
local function is_tab(lnum, col)
  return get_char(lnum, col) == "\t"
end

-- Count number of spaces back to a multiple of shiftwidth
local function count_spaces_back(lnum, col)

  -- Indentation
  local stop = vim.opt.shiftwidth._value

  if not is_before_first_non_whitespace_char(lnum, col) then
    -- Tabbing
    if vim.opt.softtabstop._value == 0 then
      return 1
    else
      stop = vim.opt.softtabstop._value
    end
  end

  local count = 0

  -- While col isn't the first column and the character is a spce
  while col >= 1 and is_space(lnum, col) do
    count = count + 1
    col = col - 1

    -- Stop counting when col is a multiple of stop
    if (col - 1) % stop == 0 then
      break
    end
  end

  return count

end

-- Insert mode backspace command for a virtual cursor
local function insert_mode_virtual_cursor_bs(vc)

  if vc.col == 1 then -- Start of the line
    if vc.lnum ~= 1 then -- But not the first line
      vim.cmd("normal! k$gJ") -- Join with previous line
      common.set_virtual_cursor_from_cursor(vc)
    end
  else

    -- Number of times to execute command, this is to backspace over tab spaces
    local count = vim.fn.max({1, count_spaces_back(vc.lnum, vc.col)})

    if vc.col == common.get_max_col(vc.lnum) then -- End of the line
      for i = 1, count do normal_bang_delete("x") end
    else -- Anywhere else on the line
      for i = 1, count do normal_bang_delete("X") end
    end
    vc.col = vc.col - count
    vc.curswant = vc.col
  end

end

-- Replace mode backspace command for a virtual cursor
-- This only moves back a character, it doesn't undo
local function replace_mode_virtual_cursor_bs(vc)

  -- First column but not first line
  if vc.col == 1 and vc.lnum ~= 1 then
    -- Move to end of previous line
    vc.lnum = vc.lnum - 1
    vc.col = common.get_max_col(vc.lnum)
    vc.curswant = vc.col
    return
  end

  -- For handling tab spaces
  local count = vim.fn.max({1, count_spaces_back(vc.lnum, vc.col)})

  -- Move left
  vc.col = vc.col - count
  vc.curswant = vc.col

end

-- Backspace command for all virtual cursors
local function virtual_cursors_bs()
  -- Replace mode
  if common.is_mode("R") then
    virtual_cursors.edit(function(vc) replace_mode_virtual_cursor_bs(vc) end, false)
  else
    virtual_cursors.edit(function(vc) insert_mode_virtual_cursor_bs(vc) end, false)
  end
end

-- Backspace command
function M.bs()
  common.feedkeys("<BS>", 0)
  virtual_cursors_bs()
end


-- Delete ----------------------------------------------------------------------

-- Delete command for a virtual cursor
local function virtual_cursor_del(vc)

  if vc.col == common.get_max_col(vc.lnum) then -- End of the line
    -- Join next line
    vim.cmd("normal! gJ")
  else -- Anywhere else on the line
    normal_bang_delete("x")
  end

  -- Cursor doesn't change
end

-- Delete command for all virtual cursors
local function virtual_cursors_del()
  virtual_cursors.edit(function(vc) virtual_cursor_del(vc) end, false)
end

-- Delete command
function M.del()
  common.feedkeys("<Del>", 0)
  virtual_cursors_del()
end


-- Carriage return -------------------------------------------------------------

-- Carriage return command for a virtual cursor
-- This isn't local because it's used by normal_to_insert
function M.virtual_cursor_cr(vc)
  if vc.col <= common.get_length_of_line(vc.lnum) then
    vim.api.nvim_put({"", ""}, "c", false, true)
    vim.cmd("normal! ==^")
    common.set_virtual_cursor_from_cursor(vc)
  else
    -- Special case for EOL: add a character to auto indent, then delete it
    vim.api.nvim_put({"", "x"}, "c", false, true)
    normal_bang_delete("==^x")
    common.set_virtual_cursor_from_cursor(vc)
    vc.col = common.get_col(vc.lnum, vc.col + 1) -- Shift cursor 1 right limited to max col
    vc.curswant = vc.col
  end
end

-- Carriage return command for all virtual cursors
-- This isn't local because it's used by normal_to_insert
function M.virtual_cursors_cr()
  virtual_cursors.edit(function(vc) M.virtual_cursor_cr(vc) end, false)
end

-- Carriage return command
-- Also for <kEnter>
function M.cr()
  common.feedkeys("<CR>", 0)
  M.virtual_cursors_cr()
end


-- Tab -------------------------------------------------------------------------

-- Get the number of spaces to put for a tab character
local function get_num_spaces_to_put(stop, col)
  return stop - ((col-1) % stop)
end

-- Put a character multiple times
local function put_multiple(char, num)
  for i = 1, num do
    vim.api.nvim_put({char}, "c", false, true)
  end
end

-- Tab command for a virtual cursor
local function virtual_cursor_tab(vc)

  local expandtab = vim.opt.expandtab._value
  local tabstop = vim.opt.tabstop._value
  local softtabstop = vim.opt.softtabstop._value
  local shiftwidth = vim.opt.shiftwidth._value

  if expandtab then
    -- Spaces
    if is_before_first_non_whitespace_char(vc.lnum, vc.col) then
      -- Indenting
      put_multiple(" ", get_num_spaces_to_put(shiftwidth, vc.col))
    else
      -- Tabbing
      if softtabstop == 0 then
        put_multiple(" ", get_num_spaces_to_put(tabstop, vc.col))
      else
        put_multiple(" ", get_num_spaces_to_put(softtabstop, vc.col))
      end
    end
  else -- noexpandtab
    -- TODO
    return
  end

  common.set_virtual_cursor_from_cursor(vc)
end

-- Tab command for all virtual cursors
local function virtual_cursors_tab()
  virtual_cursors.edit(function(vc)
    delete_if_replace_mode(vc)
    virtual_cursor_tab(vc)
  end, false)
end

-- Tab command
function M.tab()
  common.feedkeys("<Tab>", 0)
  virtual_cursors_tab()
end


-- Paste -----------------------------------------------------------------------

-- Paste line(s) at a virtual cursor in insert mode
local function virtual_cursor_insert_paste(lines, vc)
  -- Put the line(s) before the cursor
  vim.api.nvim_put(lines, "c", false, true)
end

-- Paste line(s) at a virtual cursor in replace mode
local function virtual_cursor_replace_paste(lines, vc)

  -- If the cursor is at the end of the line
  if vc.col == common.get_max_col(vc.lnum) then
    -- Put paste lines before the cursor
    vim.api.nvim_put(lines, "c", false, false)
  else -- Cursor not at the end of the line
    -- If there are multiple paste lines
    if #lines ~= 1 then
      -- Delete to the end of the line and put paste lines after the cursor
      normal_bang_delete("D")
      vim.api.nvim_put(lines, "c", true, false)
    else -- Single paste line
      local paste_line_length = #lines[1]
      local overwrite_length = common.get_length_of_line(vc.lnum) - vc.col + 1

      -- The length of the paste line is less than being overwritten
      if paste_line_length < overwrite_length then
        -- Delete the paste line length and put the paste line before the cursor
        normal_bang_delete(tostring(paste_line_length) .. "dl")
        vim.api.nvim_put(lines, "c", false, false)
      else
        -- Delete to the end of the line and put paste line after the cursor
        normal_bang_delete("D")
        vim.api.nvim_put(lines, "c", true, false)
      end
    end
  end

end

-- Paste
function M.paste(lines)
  if common.is_mode("R") then
    virtual_cursors.edit(function(vc)
      virtual_cursor_replace_paste(lines, vc)
    end, false)
  else
    virtual_cursors.edit(function(vc)
      virtual_cursor_insert_paste(lines, vc)
    end, true)
  end
end

-- Split the paste lines so that one is put to each cursor
-- The final line for the real cursor is returned
function M.split_paste(lines)
  if common.is_mode("R") then
    return virtual_cursors.split_paste(lines, virtual_cursor_replace_paste, false)
  end
    return virtual_cursors.split_paste(lines, virtual_cursor_insert_paste, true)
end

return M
