---
title: neowiki.nvim Vault-Root Search Modification
description: Documentation of changes made to neowiki.nvim to enable vault-wide file resolution for wiki-style links [[Note-Name]], allowing navigation to any file in the vault regardless of current file's directory.
---

# neowiki.nvim Vault-Root Search Modification

## Problem

The original [[neowiki.nvim]] plugin resolved wiki links (`[[File-Name]]`) **relative to the current file's directory**, not vault-root relative. This meant:

- From `/Notes/Projects/foo.md`, `[[Some-Note]]` looked for `/Notes/Projects/Some-Note.md`
- Even if `Some-Note.md` existed at `/Notes/Some-Note.md`, it would not be found
- New files were created in the current file's subdirectory

This behavior prevented true vault-style navigation where any file can link to any other file in the vault.

## Solution

Modified `lua/neowiki/core/actions.lua` to implement **vault-root fallback search**:

1. Try relative path first (backward compatible)
2. If not found, search entire vault using [[ripgrep]] (fast) or glob (fallback)
3. Create new files in vault root if not found

## Changes Made

### File: `lua/neowiki/core/actions.lua`

#### 1. Added `find_file_in_wiki()` helper function

```lua
local function find_file_in_wiki(wiki_root, filename)
  -- Extract basename for flexible matching
  local basename = vim.fn.fnamemodify(filename, ":t:r")
  
  -- Try ripgrep first for fast vault-wide search
  local rg = util.check_binary_installed({ name = "rg" })
  if rg then
    local command = {
      rg.binary, "--files", "--iglob",
      "**/*" .. basename .. "*" .. ext,
      wiki_root,
    }
    -- Search and match files by basename
  end
  
  -- Fallback to native glob
  local glob_pattern = "**/*" .. basename .. "*" .. ext
  local matches = vim.fn.globpath(wiki_root, glob_pattern, false, true)
end
```

**Purpose**: Recursively search the entire vault directory for a file matching the link target.

**Features**:
- Uses [[ripgrep]] (`rg`) when available for fast performance
- Falls back to `vim.fn.globpath()` if `rg` unavailable
- Matches by basename (case-insensitive) for flexibility

#### 2. Modified `M.follow_link()` function

**Original behavior**:
```lua
local full_path = util.join_path(active_path, filename)
add_to_history(full_path)
open_file(full_path, open_cmd)
```

**New behavior**:
```lua
-- Try relative to current file first
local full_path = util.join_path(active_path, filename)

-- If not found, search from wiki root
if vim.fn.filereadable(full_path) == 0 then
  local wiki_root = vim.b[0].wiki_root or vim.b[0].ultimate_wiki_root
  if wiki_root then
    local search_filename = filename:gsub("^%./", "")
    local found_path = find_file_in_wiki(wiki_root, search_filename)
    if found_path then
      full_path = found_path
    else
      -- Create new file in wiki root
      full_path = util.join_path(wiki_root, search_filename)
    end
  end
end

add_to_history(full_path)
open_file(full_path, open_cmd)
```

**Key additions**:
- Check if file exists with `vim.fn.filereadable()`
- Get wiki root from buffer variables (`wiki_root` or `ultimate_wiki_root`)
- Strip leading `./` from processed filename
- Call `find_file_in_wiki()` for vault-wide search
- Fallback to creating file in vault root

## How It Works Now

Given vault structure:
```
~/Documents/Notes/
├── index.md
├── Daily-Notes.md
└── Projects/
    ├── foo.md        <-- you are here
    └── bar.md
```

From `Projects/foo.md`:

| Link | Old Behavior | New Behavior |
|------|-------------|--------------|
| `[[bar]]` | Opens `Projects/bar.md` ✅ | Same ✅ |
| `[[Daily-Notes]]` | Creates `Projects/Daily-Notes.md` ❌ | Opens `~/Documents/Notes/Daily-Notes.md` ✅ |
| `[[New-Idea]]` | Creates `Projects/New-Idea.md` ❌ | Creates `~/Documents/Notes/New-Idea.md` ✅ |

## Installation

The modified version is installed at:
```
~/.local/share/nvim/plugged/neowiki.nvim
```

**Source**: Fork at [[https://github.com/moisestohias/neowiki.nvim]]

## Configuration

In your `init.vim`:

```vim
" Use forked version
Plug 'moisestohias/neowiki.nvim'

lua << EOF
local ok, neowiki = pcall(require, 'neowiki')
if ok then
  neowiki.setup({
    wiki_dirs = {
      { name = "Notes", path = "~/Documents/Notes" },
    },
  })
  
  -- Global wiki keymaps
  vim.keymap.set("n", "<leader>ww", neowiki.open_wiki, { desc = "Open Wiki" })
  vim.keymap.set("n", "<leader>wW", neowiki.open_wiki_floating, { desc = "Open Wiki (Floating)" })
  vim.keymap.set("n", "<leader>wT", neowiki.open_wiki_new_tab, { desc = "Open Wiki (Tab)" })
end
EOF
```

## Keybindings (Plugin Default)

| Key | Action |
|-----|--------|
| `<CR>` | Follow link (current buffer) |
| `<S-CR>` | Follow link (vertical split) |
| `<C-CR>` | Follow link (horizontal split) |
| `<Tab>` / `<S-Tab>` | Jump between links |
| `[[` / `]]` | Navigate back/forward in history |
| `<BS>` | Jump to index |

## Dependencies

- [[ripgrep]] (`rg`) - Highly recommended for fast vault-wide search
- `nvim-treesitter` - For robust markdown link parsing

---

**Commit**: `d3ec88d` - "feat: add vault-root fallback for wiki links"
