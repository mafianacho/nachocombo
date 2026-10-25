# Menu Bar Organizer — real macOS constraints and the MVP scope

## OS constraints (as of macOS 12 Monterey)
- There is **no public API to enumerate, hide or reorder other apps' menu bar icons (NSStatusItem).**
  Each app owns only its own items. Icon order comes from the user's ⌘-drag and from creation order.
- Bartender-like apps rely on Accessibility and Screen Recording permissions and on private behavior. This MVP uses no private
  APIs and does not work around permissions.

## MVP approach: collapsing with a divider
- The app creates two `NSStatusItem`s (a toggle `‹ ›` and a divider `┊`). The toggle is rightmost, the divider just left of it.
- Collapsed: the divider's `length` grows to 10,000 pt, which **pushes the icons left of it off the screen.** Expanded: back to `variableLength`.
- The user ⌘-drags the icons to hide to the left of the divider. The app cannot move other apps' icons itself.
- No permission needed. When the module is turned OFF, both items are removed with `removeStatusItem`, so the push is undone at once.
- An item created later by another module (for example the System Monitor) lands left of the divider (the hidden side), so the app
  then recreates the divider pair to keep its own items on the visible side.

## Limits (not done in the MVP)
- Automatic selection of icons to hide or a list UI, temporary expansion on hover or by hotkey, revealing a single icon while collapsed.
- What happens when the icons left of the divider are wider than the screen depends on how the OS lays them out (needs checking).
