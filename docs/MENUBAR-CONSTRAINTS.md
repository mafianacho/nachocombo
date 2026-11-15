# Menu Bar Organizer — real macOS constraints and scope

## OS constraints (macOS 12 Monterey to macOS 15 Sequoia)
- There is **no public API to enumerate, hide or reorder other apps' menu bar icons (NSStatusItem).**
  Each app owns only its own items. Icon order comes from the user's ⌘-drag and from creation order.
- Full menu bar managers read and move other apps' items with Accessibility, read their pictures with Screen Recording and
  use private window server calls. This gadget uses no private APIs, needs no permission and never works around one.

## Approach: collapsing with a divider
- The gadget creates its own `NSStatusItem`s: a toggle `‹ ›` (right-most), a divider `┊` just left of it and, with the
  always-hidden option, a second divider further left.
- Collapsed: the divider's `length` grows to `max(500, min(widest screen × 2, 10,000))` pt (10,000 pt is the cap macOS puts
  on a status item), which **pushes the icons left of it off the screen.** Expanded: back to `variableLength`.
- Always-hidden section: while expanded, the second divider takes the long length instead, so only the icons between the
  two dividers come back. ⌥-click (or right-click) on the toggle, or the optional shortcut, shows them too until the next
  collapse.
- The user ⌘-drags the icons to hide to the left of a divider. The app cannot move other apps' icons itself.
- Auto-collapse: after 5–60 s (10 s by default) the icons fold away again; the countdown waits while the pointer is in the
  menu bar. With "expand on hover", resting the pointer on `‹` for 0.3 s expands, and leaving the menu bar folds it again.
- No permission needed. When the gadget is turned OFF, every item is removed with `removeStatusItem`, so the push is undone
  at once.
- An item created later by another gadget (for example the System Monitor) lands left of the divider (the hidden side), so
  the app then recreates its items to keep them on the visible side.
- After collapsing, the gadget checks that the divider's window really grew. If macOS kept it small (macOS 27 betas render
  the whole menu bar as one window and eject a stretched item), it reports this in the gallery and stays expanded.

## Limits
- No automatic selection of icons to hide, no list or search of other apps' icons, no second bar below the menu bar:
  all of these need Accessibility, Screen Recording and private APIs.
- On a Mac with a camera notch, icons that end up under the notch cannot be shown.

## MCP / Nacho tools (NACHO-148)
Tools `menubar_status`, `menubar_list_items` (read), `menubar_tidy`, `menubar_set_collapsed`, `menubar_show_hidden` (change); guide
`nachocombo://gadgets/menubar/guide`, prompt `menubar_organize`.
- **Reading** other apps' items uses the public Accessibility API (`AXExtrasMenuBar` of each running app: position, size, title). It needs the
  Accessibility permission; without it the result is `permission_needed`. Zones (`visible` / `hidden` / `always_hidden`) come from the x of the
  organizer's own divider windows; items pushed off screen by a folded divider still report their (off-screen) position.
- **Folding** only drives the gadget's own dividers (as before). `menubar_tidy` = fold now and drop the always-hidden view.
- **Hiding / showing ONE other app's item: no tool.** The only public route is synthesizing a ⌘-drag with CGEvent from the item's AX position to
  the left of the divider. It needs the Accessibility permission to post events, moves the real pointer, and depends on item positions and
  drag behaviour that differ by macOS version (macOS 26/27 changed the menu bar window layout), which cannot be checked without a real Mac.
  So the guide tells the user to ⌘-drag by hand. If a tool is wanted, NACHO-148 asks for a decision (risk `input_inject`, real-Mac check first).
