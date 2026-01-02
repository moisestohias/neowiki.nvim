-- lua/neowiki/core/link.lua
local util = require("neowiki.util")
local state = require("neowiki.state")

local M = {}

-- TOGGLE: Set to false to disable Treesitter and force Regex fallback (for testing)
local USE_TREESITTER = true

-- CONSTANTS: Regex Patterns
-- 1. Wikilink: [[target]]
-- Matches [[target]]. Uses non-greedy (.-) to handle multiple links on one line.
local PATTERN_WIKI = "%[%[(.-)%]%]"

-- 2. Markdown Link (Balanced): [text](target) OR ![text](target)
-- Capture 1: Display text (bracketed, with optional leading !)
-- Capture 2: The balanced parens (target wrapper)
-- Improvement: Uses %b() to correctly handle nested parens in paths (e.g. file(1).md)
local PATTERN_MD_BALANCED = "(!?%[[^%]]*%])(%b())"

-- 3. Markdown Link (Angle Brackets): [text](<target>)
-- Capture 1: Display text
-- Capture 2: Target inside <...>
local PATTERN_MD_ANGLE = "(!?%[[^%]]*%])%(<(.-)>%)"

---
-- Helper to check if a node type is a valid markdown link container
local function is_link_node(node_type)
  return node_type == "inline_link"
    or node_type == "full_reference_link"
    or node_type == "shortcut_link"
    or node_type == "image"
end

---
-- Uses Treesitter to extract link target under cursor.
-- Returns nil if TS is unavailable, disabled, or no link is found.
local function get_ts_link_target()
  if not USE_TREESITTER then
    return nil
  end

  local ok, ts_utils = pcall(require, "nvim-treesitter.ts_utils")
  if not ok then
    return nil
  end

  local node = ts_utils.get_node_at_cursor()
  if not node then
    return nil
  end

  local expr = node
  while expr do
    local ntype = expr:type()
    -- Safety: Ignore links inside code blocks
    if ntype == "code_span" or ntype == "fenced_code_block" or ntype == "code_block" then
      return nil
    end

    if is_link_node(ntype) then
      for child in expr:iter_children() do
        if child:type() == "link_destination" then
          return vim.treesitter.get_node_text(child, 0)
        end
      end
    end
    expr = expr:parent()
  end
  return nil
end

---
-- A generic function that iterates through all links on a line and applies
-- a transformation based on the provided logic.
-- @param line (string) The line of text to process.
-- @param transform_logic (function) A function that receives a context table for
--   each link found and returns a replacement string, or nil to make no change.
-- @return (string, number) The modified line and the count of replacements.
--
local function generic_link_transformer(line, transform_logic)
  local total_replacements = 0

  local function replacer(context)
    local replacement = transform_logic(context)
    if replacement ~= nil then
      total_replacements = total_replacements + 1
      return replacement
    else
      return context.full_markup
    end
  end

  -- 1. Handle angle bracket links: [text](<target>)
  line = line:gsub(PATTERN_MD_ANGLE, function(link_text_part, raw_target)
    return replacer({
      type = "markdown",
      display_text = link_text_part:match("^!?%[(.*)%]$"),
      raw_target = raw_target,
      full_markup = link_text_part .. "(<" .. raw_target .. ">)",
    })
  end)

  -- 2. Handle standard/balanced links: [text](target)
  line = line:gsub(PATTERN_MD_BALANCED, function(link_text_part, target_parens)
    -- Strip the surrounding parentheses from %b() capture
    local raw_target = target_parens:sub(2, -2)
    return replacer({
      type = "markdown",
      display_text = link_text_part:match("^!?%[(.*)%]$"),
      raw_target = raw_target,
      full_markup = link_text_part .. target_parens,
    })
  end)

  -- 3. Handle wikilinks: [[target]]
  line = line:gsub(PATTERN_WIKI, function(raw_target)
    return replacer({
      type = "wikilink",
      display_text = raw_target,
      raw_target = raw_target,
      full_markup = "[[" .. raw_target .. "]]",
    })
  end)

  return line, total_replacements
end

---
-- Finds all valid markdown link targets on a single line of text.
-- @param line (string): The line to search.
-- @return (table): A list of processed link targets found on the line.
--
local function find_all_link_targets(line)
  local targets = {}
  generic_link_transformer(line, function(ctx)
    local processed = util.process_link_target(ctx.raw_target, state.markdown_extension)
    if processed then
      table.insert(targets, processed)
    end
    return nil -- No replacement, just discovery
  end)
  return targets
end
---
-- Scans the current buffer for markdown links that point to non-existent files.
-- @return (table) A list of objects, where each object represents a line
--   containing at least one broken link. Each object contains `lnum` and `text`.
--   Returns an empty table if no broken links are found.
--
M.find_broken_links_in_buffer = function()
  local broken_links_info = {}
  local current_buf_path = vim.api.nvim_buf_get_name(0)
  if not current_buf_path or current_buf_path == "" then
    return broken_links_info -- Not a file buffer
  end

  local current_dir = vim.fn.fnamemodify(current_buf_path, ":p:h")
  local all_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)

  for i, line in ipairs(all_lines) do
    local has_broken_link_on_line = false
    local link_targets = find_all_link_targets(line)

    for _, target in ipairs(link_targets) do
      -- Ignore external URLs when checking for broken file links.
      if not util.is_web_link(target) then
        local full_target_path = util.join_path(current_dir, target)
        full_target_path = vim.fn.fnamemodify(full_target_path, ":p")
        -- A link is considered broken if the target file isn't readable.
        if vim.fn.filereadable(full_target_path) == 0 then
          has_broken_link_on_line = true
          break -- One broken link is enough to mark the entire line.
        end
      end
    end

    if has_broken_link_on_line then
      table.insert(broken_links_info, {
        filename = current_buf_path,
        lnum = i,
        text = line,
      })
    end
  end

  return broken_links_info
end

---
-- Processes a line to find and extract a link based on cursor position or a search pattern.
-- The function operates in two modes:
-- 1. **Cursor Mode** (default): When `pattern_to_match` is nil, it finds the link
--    (Markdown or Wikilink) that is currently under the editor's cursor.
-- 2. **"Hungry" Mode**: When `pattern_to_match` is a string, it ignores the cursor
--    and returns the *first* link found whose target contains `pattern_to_match`
--    as a substring.
-- @param cursor table A table representing the cursor's position, where `cursor[2]` is the 0-indexed column.
-- @param line string The line of text to be analyzed.
-- @param pattern_to_match string|nil The substring to search for in link targets ("hungry mode"), or nil to use cursor position.
-- @return string|nil The processed link target if a match is found, otherwise nil.
M.process_link = function(cursor, line, pattern_to_match)
  -- 1. Hungry Mode (Search by pattern)
  -- Used for rename/delete operations to find specific targets on a line.
  if pattern_to_match then
    -- Standard/Balanced Markdown links
    local search_pos = 1
    while true do
      local s, e, _, target_parens = line:find(PATTERN_MD_BALANCED, search_pos)
      if not s then
        break
      end
      search_pos = e + 1
      local target = target_parens:sub(2, -2)
      if target and target:find(pattern_to_match, 1, true) then
        return util.process_link_target(target, state.markdown_extension)
      end
    end

    -- Angle Bracket Markdown links
    search_pos = 1
    while true do
      local s, e, _, target = line:find(PATTERN_MD_ANGLE, search_pos)
      if not s then
        break
      end
      search_pos = e + 1
      if target and target:find(pattern_to_match, 1, true) then
        return util.process_link_target(target, state.markdown_extension)
      end
    end

    -- Wikilinks
    search_pos = 1
    while true do
      local s, e, target = line:find(PATTERN_WIKI, search_pos)
      if not s then
        break
      end
      search_pos = e + 1
      if target and target:find(pattern_to_match, 1, true) then
        return util.process_link_target(target, state.markdown_extension)
      end
    end
    return nil
  end

  -- 2. Cursor Mode

  -- A. Try Treesitter (Best for context awareness)
  local ts_target = get_ts_link_target()
  if ts_target then
    return util.process_link_target(ts_target, state.markdown_extension)
  end

  -- B. Treesitter Safety Check (Block Detection)
  -- Uses `ignore_injections = true` to check the HOST (Markdown) tree.
  -- This ensures we detect code blocks even if the language inside is injected (e.g., Python).
  if USE_TREESITTER and vim.treesitter and vim.treesitter.get_node then
    local node = vim.treesitter.get_node({ ignore_injections = true })
    while node do
      local ntype = node:type()
      if
        ntype == "code_span"
        or ntype == "fenced_code_block"
        or ntype == "code_block"
        or ntype == "block_quote"
      then
        return nil -- Cursor is in a "safe" block; do not process regex.
      end
      node = node:parent()
    end
  end

  local col = cursor[2] + 1

  -- C. Regex Fallback
  -- (Prioritize Wikilinks since standard links are likely handled by TS)

  -- Wikilinks
  do
    local search_pos = 1
    while true do
      local s, e, target = line:find(PATTERN_WIKI, search_pos)
      if not s then
        break
      end
      search_pos = e + 1
      if col >= s and col <= e then
        return util.process_link_target(target, state.markdown_extension)
      end
    end
  end

  -- Standard/Balanced Markdown links
  do
    local search_pos = 1
    while true do
      local s, e, _, target_parens = line:find(PATTERN_MD_BALANCED, search_pos)
      if not s then
        break
      end
      search_pos = e + 1
      if col >= s and col <= e then
        local target = target_parens:sub(2, -2)
        return util.process_link_target(target, state.markdown_extension)
      end
    end
  end

  -- Angle Bracket Markdown links
  do
    local search_pos = 1
    while true do
      local s, e, _, target = line:find(PATTERN_MD_ANGLE, search_pos)
      if not s then
        break
      end
      search_pos = e + 1
      if col >= s and col <= e then
        return util.process_link_target(target, state.markdown_extension)
      end
    end
  end

  return nil
end

---
-- Finds and transforms all links on a line that match a specific filename pattern.
-- @param line (string) The line containing links.
-- @param pattern_to_match (string) The substring to find within a link's target.
-- @param transform_fn (function) A function that returns the new link markup.
-- @return (string, number) The modified line and the total count of replacements made.
--
M.find_and_transform_link_markup = function(line, pattern_to_match, transform_fn)
  return generic_link_transformer(line, function(contex)
    if contex.raw_target and contex.raw_target:find(pattern_to_match, 1, true) then
      -- Call the original transform_fn, maintaining its signature for compatibility.
      if contex.type == "markdown" then
        return transform_fn("[" .. contex.display_text .. "]", contex.raw_target)
      else -- wikilink
        return transform_fn(contex.display_text)
      end
    end
    return nil -- No match, so no change.
  end)
end

---
-- Finds and removes the markup for broken local links on a single line, preserving text.
-- This function is used by the cleanup_broken_links action.
-- @param line (string) The line to process.
-- @param current_dir (string) The absolute path of the file's directory.
-- @return (string, boolean) The modified line and a boolean indicating if changes were made.
--
M.remove_broken_markup = function(line, current_dir)
  local modified_line, count = generic_link_transformer(line, function(context)
    if not util.is_web_link(context.raw_target) then
      -- To check the file path, we need the fully processed target name.
      local processed_target =
        util.process_link_target(context.raw_target, state.markdown_extension)
      local full_target_path = util.join_path(current_dir, processed_target)

      -- If the file is not readable, it's a broken link.
      if vim.fn.filereadable(full_target_path) == 0 then
        -- Return just the display text to remove the link markup.
        return context.display_text
      end
    end
    return nil -- Link is valid or is a web link, so no change.
  end)
  return modified_line, count > 0
end

return M
