# claudediff.nvim

> **Disclaimer.** This is a personal-use plugin, vibe-coded end-to-end with an AI assistant. It works on my machine, it solves my problem, and I'm putting it on GitHub so I can install it via lazy. No tests, no guarantees, no support. If it breaks your editor, you get to keep both pieces. Fork freely.

Inline diff view for [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim). Replaces the default side-by-side `:diffthis` renderer with Claude's proposed changes applied directly to the real file buffer, with removed lines shown as red virtual lines above the replacement.

LSP, treesitter, formatters, and your keybindings all run on the proposed content — because the buffer *is* the proposal. Accept with `:w`, reject with `:e!`, or use the configured keymaps.

## Requirements

- Neovim 0.10+
- [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim) installed and working

## Install

lazy.nvim:

```lua
{
  "thobiasn/claudediff.nvim",
  dependencies = { "coder/claudecode.nvim" },
  config = true,
}
```

packer:

```lua
use {
  "thobiasn/claudediff.nvim",
  requires = "coder/claudecode.nvim",
  config = function() require("claudediff").setup() end,
}
```

No configuration. `setup()` takes no arguments — it just installs the patch.

## Usage

When Claude proposes an edit:

1. The target file opens (or gets focused) in an editor window.
2. Proposed content is applied to the buffer. Removed lines render as red `virt_lines`; added lines are tinted green.
3. **Accept**: `:w` (or respond yes in the Claude prompt) — Claude writes the file to disk.
4. **Reject**: close the buffer (`:bd`, `:bw`, bufferline close, or respond no in the Claude prompt) — buffer reloads from disk.

Editing the proposal before saving is supported — `:w` persists your edits as the final content.

## Health check

```
:checkhealth claudediff
```

Verifies `claudecode.diff` is loadable and that the upstream symbols this plugin depends on still exist. If upstream ever renames or removes them, this will tell you immediately rather than at the next Claude edit.

## How it works (and the hack you should know about)

Claudecode has no public "diff renderer" extension point. This plugin monkey-patches `claudecode.diff.open_diff_blocking` on the cached module table and reaches into several underscore-prefixed functions:

- `_register_diff_state`
- `_resolve_diff_as_saved`
- `_resolve_diff_as_rejected`
- `_cleanup_diff_state`

These are private by convention. If the claudecode maintainers rename or refactor them, this plugin breaks. The health check exists specifically to surface that failure early. The plugin is tested against claudecode.nvim `main` as of this repo's last commit — pin both if you want stability.

The rest of the design is standard Neovim:

- `buftype=acwrite` on the target buffer during a pending diff, so `:w` hits our `BufWriteCmd` handler instead of writing to disk. Claude is responsible for the actual disk write after receiving `FILE_SAVED`.
- Extmark overlay (`virt_lines` for removed, range highlights for added), cleared on accept/reject/wipeout.
- Buffer-local keymaps and a scoped augroup, both torn down on resolution.
- Atomic setup: if any part of the install fails, the buffer is restored to its pre-diff state.

No global state. No new commands. No windows or tabs created beyond focusing an existing editor window (or splitting if none exists).

## What this plugin will not do

- Modify claudecode's protocol, WebSocket, or tool-call handling
- Persist the file to disk itself (Claude does that)
- Support side-by-side or external diff tools
- Work with edits when the target file has unsaved changes — you'll see an error; save or discard first

## Acknowledgments

Built against [`coder/claudecode.nvim`](https://github.com/coder/claudecode.nvim), which handles all MCP protocol, WebSocket transport, and diff-state management. This plugin only replaces the diff renderer.

## License

MIT — see [LICENSE](./LICENSE).
