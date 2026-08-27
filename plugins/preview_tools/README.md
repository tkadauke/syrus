# Preview Tools

Preview Tools gives planning-mode chat agents a safe scratch area for building lightweight HTML, CSS, and JavaScript previews. The tools are scoped away from repository checkouts, so agents can mock up ideas and show interactive artifacts without modifying project code.

Use this plugin when chat should support exploratory UI sketches before a real job is filed. It is intentionally separate from repository preview providers, which run actual application code from workflow workspaces.

## What It Adds

- Scratch-file write and edit tools for chat.
- Preview open/close tools for generated mockups.
- A constrained workspace that is not the attached repository checkout.

## When To Enable

Enable Preview Tools for planning-heavy or design-heavy instances where users often want quick visual mockups. Disable it if chat should remain read-only except for normal job proposals.

## Operational Notes

Scratch previews are disposable. Agents should move real implementation work into jobs or coding-mode handoffs rather than treating scratch output as production source.
