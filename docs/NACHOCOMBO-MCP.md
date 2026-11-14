# NachoCombo MCP

**Status:** contract and skeleton (NACHO-145, parent NACHO-144). Core is covered by `swift test` (Linux and macOS CI); the macOS wiring is compiled in CI only and **has not been run on a real Mac**.

NachoCombo MCP puts every Nacho Combo gadget behind **one tool registry** and offers it through **two exits**:

| Exit | Who uses it | Code | Names | Gate |
|---|---|---|---|---|
| (a) NachoCombo MCP server | external MCP clients holding an API key | `ComputerUseService` (alias `NachoComboMCPService`) | `<gadget>_<action>` | API key, LAN/TLS, emergency stop, tool group switches (Computer Use) and **gadget switches** (every other gadget), all off by default |
| (b) nacho-server connector | Nacho in the chat | `PetConnectorClient` (`combo_*` capabilities) | `combo_<gadget>_<action>` | risk → `"approval": "required"`, per-gadget "always allow" (off by default), per-action `disabled` |

The server is the former Computer Use MCP server, extended: `serverInfo.name` is `NachoCombo MCP`, `initialize` declares `tools`, `resources` and `prompts`. Everything in [COMPUTER-USE-MCP.md](COMPUTER-USE-MCP.md) (keys, LAN/TLS, rate limits, emergency stop, call log without content) still applies.

## Files

| What | File | Owner |
|---|---|---|
| Contract types (`GadgetID`, `GadgetToolRisk`, `GadgetTool`, `GadgetSchema`) | `Sources/NachoComboCore/Gadgets/GadgetToolContract.swift` | contract lane |
| Registry, order, integrity check | `Sources/NachoComboCore/Gadgets/GadgetToolRegistry.swift` | contract lane |
| Guides and prompts (types, rendering) | `Sources/NachoComboCore/Gadgets/GadgetGuide.swift` | contract lane |
| Runner protocol, dispatcher, shared results, `PetCommandToolRunner` | `Sources/NachoComboCore/Gadgets/GadgetToolDispatch.swift` | contract lane |
| "Always allow" store + `disabled` extension point | `Sources/NachoComboCore/Gadgets/GadgetTrust.swift` | contract lane |
| **One provider per gadget** (tools, guide, prompts) | `Sources/NachoComboCore/Gadgets/Tools/<Gadget>Tools.swift` | that gadget's lane |
| MCP server | `Sources/NachoComboCore/ComputerUseService.swift` | contract lane |
| Connector bridge | `Sources/NachoComboCore/Pet/PetConnectorClient.swift`, `PetCommands.swift` | contract lane |
| App wiring (runner registration, gadget/permission state, trust file) | `Sources/NachoCombo/AppDelegate.swift` `wireNachoComboMCP()` | contract lane |

Every gadget already has a provider file (empty ones for menubar, monitor, disk, clipboard, capture, awake, mouse, calendar) and `GadgetToolRegistry.providers` already lists them, so a lane never edits the registry file.

## Gadget ids

| id | Module | id | Module |
|---|---|---|---|
| `combo` | Nacho Combo itself (gadgets, workspaces, guides) | `dim` | Focus Dim |
| `window` | Window Snap | `awake` | Keep Awake |
| `menubar` | Menu Bar Organizer | `device` | Device Control |
| `monitor` | System Monitor | `mouse` | Mouse Tune |
| `disk` | Disk Map | `appswitch` | App Switch (apps: list, open, focus, hide, quit) |
| `clipboard` | Clipboard History | `calendar` | Calendar Clock |
| `shelf` | File Shelf | `computer` | Computer Use |
| `capture` | Capture Float | | |

## Tool fields

| Field | Rule |
|---|---|
| `gadget`, `action` | `action` is lower-case words joined by `_` |
| MCP name | `<gadget>_<action>` (`combo_<action>` for `combo`). No dots: Claude-family clients accept only `^[a-zA-Z0-9_-]{1,64}$` |
| connector name | `combo_<gadget>_<action>` (`combo_<action>` for `combo`), ≤ 64. Must not contain `pay purchase checkout buy call delete remove publish book reserve send post` (nacho-server `classify_name` would file it as payment/deletion/message) |
| `korean` | ≤ 200 characters, mostly Korean, what + when (Nacho's tool picker chooses by it) |
| `english` | ≤ 400 characters (MCP clients) |
| `input` | closed JSON schema: `type: object`, `properties`, `additionalProperties: false`, every `required` key a property (nested item objects too) |
| `output` | one short line about the result |
| `risk` | `read` / `change` / `content_out` / `input_inject` / `destructive` |
| `permissions` | macOS permissions the tool needs (`accessibility`, `screenRecording`, `automation`) |
| `exits` | `.mcp`, `.connector` (default both) |
| `aliases`, `legacyConnectorName`, `legacyMCPName` | old names still accepted |
| `mcpGroup` | Computer Use tools only: the tool group switch they sit under |
| `requiresGadgetOn` | default true: the dispatcher answers `gadget_off` while the module is off (migrated tools: false, unchanged behaviour) |

`GadgetToolRegistry.problems()` checks all of it (`GadgetRegistryTests.testRegistryKeepsTheContract`): unique names across new names and aliases on each exit, length, pattern, forbidden words, descriptions, schema shape, guide examples, prompt names.

**Reserved MCP names.** The old Computer Use names stay accepted as aliases, so no new tool may take them: `window_list`, `window_set_frame`, `window_minimize`, `clipboard_read`, `clipboard_write`, `mouse_move`, `mouse_click`, `mouse_drag`, `mouse_scroll`, `app_*`, `screen_*`, `open_url`, `open_file`, `key_press`, `type_text`, `system_info`, `process_list`, `process_kill`, `file_read`, `file_write`, `shell_run`, `applescript_run`. (That is why the window list is `window_list_windows`.) The integrity test fails on a clash.

## Risk and approval

| Risk | Meaning | Connector (Nacho) | MCP client |
|---|---|---|---|
| `read` | state and lists (numbers, kinds, lengths, names) | runs at once | under its switch |
| `change` | visible, undoable change | runs at once | under its switch |
| `content_out` | sends content off the Mac (clipboard text or preview, capture image, a file itself) | `"approval": "required"` every time; **no approval** while the gadget is "always allowed" | under its switch |
| `input_inject` | types, clicks, presses keys | same as `content_out` | under its switch |
| `destructive` | cannot be undone (quit, kill, overwrite, scripts) | `"approval": "required"` **always** ("always allow" is ignored) | under its switch; high-risk groups keep their own switches |

Approval is for **content**: a list of clipboard items (number, kind, length) is `read`; the item's text is `content_out`. So list tools carry no previews.

The approval card on the server has no "always allow" choice for connector actions (`rule_options_for` only offers rules for payment/booking/message kinds; connector actions are `other`). The only "always allow" is the per-gadget switch in the app.

### "Always allow" and the revoke race

- Store: `GadgetTrust.shared`, per gadget, default off, `~/Library/Application Support/NachoCombo/gadget-trust.json` (next to `settings.json`, like the workspaces file). Only gadgets with a `content_out` / `input_inject` connector tool can be switched (none ship yet; the computer use / data gadget lanes add them).
- A change notifies the connector, which sends `{"type":"capabilities","capabilities":[…]}` at once, followed by a ping.
- The app remembers what the server believes (`confirmedAllowed`): the hello, or the last `capabilities` frame once the pong behind it arrived (frames on one socket are handled in order).
- **Race:** after "always allow" is switched off, the server may still forward a call under the old declaration (no card). Until the pong arrives, such a `content_out` / `input_inject` request is refused with `ok:false, reason:"approval_revoked"` and a hint to call again (then the card shows). No pong within 10 s: the connection is reopened and hello declares fresh.
- `disabled` (NACHO-131 extension point): connector names in `GadgetTrust.shared.disabled` are not declared and are refused with `reason:"action_disabled"`. Memory only; NACHO-131 decides storage and screen.

### Shared results

All are `ok:false` with `reason`, an English `hint` for the model and Korean `guide_ko` for the user. The app never draws a card itself.

| reason | When | hint |
|---|---|---|
| `gadget_off` | the gadget's module is off | `ask the user with ask_choice, then call combo_set_gadget` |
| `permission_needed` | a macOS permission is missing (`permission` field) | tell the user how to allow it (`guide_ko`: 시스템 설정 > 개인정보 보호 및 보안 > …) |
| `approval_revoked` | revoke race (above) | call again; the user will be asked |
| `action_disabled` | switched off by the user | do not retry |
| `unavailable` | no runner registered for the gadget | do not retry |

## Guides and prompts

- Each gadget writes one `GadgetGuide` in its provider (summary, what it can do, order of calls, example calls, limits). The text is the same on both exits; only tool names follow the exit.
- MCP: `resources/list` lists `nachocombo://gadgets/<id>/guide` (`text/markdown`) for every gadget with a guide; `resources/read` renders it with MCP names; an unknown URI is JSON-RPC error `-32002`.
- Nacho: `combo_gadget_guide {"gadget":"<id>"}` (connector only, `read`) answers `{ok, gadget, guide}` with connector names. A gadget without a guide answers its tool names.
- Prompts: `GadgetPrompt` (name `<gadget>_<flow>`, arguments, template). `prompts/list`, `prompts/get` (unknown or missing required argument → `-32602`). Example: `window_side_by_side`.
- Guides so far: `combo`, `window` (format examples), `menubar`. Every gadget lane writes its own.

## MCP request handling

Unchanged order of checks, with the switch step extended: … → JSON-RPC → emergency stop → **tool group switch (Computer Use) or gadget switch (other gadgets)** → backend (Computer Use, one at a time) or gadget runner (`GadgetToolDispatcher.runAndWait`, 60 s limit). `tools/list` lists exactly what may be called; the emergency stop hides everything. Gadget switches: `ComputerUseSettings.enabledGadgets` in `settings.json` → `computerUse.enabledGadgets` (missing or broken = all off). There is no settings screen for them yet; for testing, `ctl mcp gadget <id> on|off` (and `ctl trust <id> on|off` for "always allow"). The call log keeps the name the client used, never arguments or results.

Gadget tool results come back as one text content with the JSON result (`{"ok":…,"message":…,…}`), `isError` = `!ok`.

## Rename table

### Connector capabilities (16)

nacho-server already knows these names (allow rules saved on the server use them), so they stay the **declared** names while `GadgetToolRegistry.declaresCanonicalConnectorNames` is off; the new names are accepted as aliases. Turn the flag on together with the server, then the old names become the aliases. Hello order is unchanged (these 16 first).

| Declared (old) | New canonical name (alias) | MCP name | Risk |
|---|---|---|---|
| `combo_arrange_window` | `combo_window_arrange` | `window_arrange` | change |
| `combo_layout_windows` | `combo_window_layout` | `window_layout` | change |
| `combo_list_windows` | `combo_window_list_windows` | `window_list_windows` | read |
| `combo_list_apps` | `combo_appswitch_list` | `appswitch_list` | read |
| `combo_open_app` | `combo_appswitch_open` | `appswitch_open` | change |
| `combo_focus_app` | `combo_appswitch_focus` | `appswitch_focus` | change |
| `combo_hide_app` | `combo_appswitch_hide` | `appswitch_hide` | change |
| `combo_quit_app` | `combo_appswitch_quit` | `appswitch_quit` | destructive (declared only while `PetCommands.declaresQuitApp`, on since PR #27) |
| `combo_set_system` | `combo_device_set` | `device_set` | change |
| `combo_set_gadget` | `combo_set_gadget` | `combo_set_gadget` | change |
| `combo_list_gadgets` | `combo_list_gadgets` | `combo_list_gadgets` | read |
| `combo_set_dim_strength` | `combo_dim_set_strength` | `dim_set_strength` | change |
| `combo_clear_shelf` | `combo_shelf_clear` | `shelf_clear` | change |
| `combo_workspace_save` | `combo_workspace_save` | `combo_workspace_save` | change |
| `combo_workspace_apply` | `combo_workspace_apply` | `combo_workspace_apply` | change |
| `combo_workspace_list` | `combo_workspace_list` | `combo_workspace_list` | read |
| (new) | `combo_gadget_guide` | — (MCP has resources) | read |

On the MCP exit these run through `PetCommandToolRunner` → `PetCommands.parse` (the old checks) → the pet's executor, under the gadget switch of `combo`, `window`, `appswitch`, `device`, `dim` or `shelf`.

### Computer Use MCP tools (26)

`tools/list` shows the new names; `tools/call` accepts both; the backend still runs the old name. Not offered to Nacho yet (computer use lane).

| Old (alias) | New | Tool group | Risk |
|---|---|---|---|
| `screen_list_displays` | `computer_screen_list_displays` | screen | read |
| `screen_capture` | `computer_screen_capture` | screen | content_out |
| `app_list` | `computer_app_list` | appsWindows | read |
| `app_open` | `computer_app_open` | appsWindows | change |
| `app_activate` | `computer_app_activate` | appsWindows | change |
| `app_quit` | `computer_app_quit` | appsWindows | destructive |
| `window_list` | `computer_window_list` | appsWindows | read |
| `window_set_frame` | `computer_window_set_frame` | appsWindows | change |
| `window_minimize` | `computer_window_minimize` | appsWindows | change |
| `mouse_move` | `computer_mouse_move` | input | input_inject |
| `mouse_click` | `computer_mouse_click` | input | input_inject |
| `mouse_drag` | `computer_mouse_drag` | input | input_inject |
| `mouse_scroll` | `computer_mouse_scroll` | input | input_inject |
| `key_press` | `computer_key_press` | input | input_inject |
| `type_text` | `computer_type_text` | input | input_inject |
| `clipboard_read` | `computer_clipboard_read` | clipboard | content_out |
| `clipboard_write` | `computer_clipboard_write` | clipboard | change |
| `open_url` | `computer_open_url` | openItems | change |
| `open_file` | `computer_open_file` | openItems | change |
| `system_info` | `computer_system_info` | systemInfo | read |
| `process_list` | `computer_process_list` | systemInfo | read |
| `applescript_run` | `computer_applescript_run` | appleScript | destructive |
| `shell_run` | `computer_shell_run` | shell | destructive |
| `file_read` | `computer_file_read` | fileAccess | content_out |
| `file_write` | `computer_file_write` | fileAccess | destructive |
| `process_kill` | `computer_process_kill` | processControl | destructive |

## Adding tools (gadget lane checklist)

1. Work only in your `Sources/NachoComboCore/Gadgets/Tools/<Gadget>Tools.swift` (append; do not change existing entries — if one must change, report [막힘] to 코드카포).
2. Add `GadgetTool(gadget:action:korean:english:input:output:risk:permissions:)`. Pick the risk by the table above (content leaving the Mac = `content_out`, lists = `read`). New tools keep `requiresGadgetOn: true`.
3. Implement `GadgetToolRunning` in the app (`Sources/NachoCombo/…`, hop to the main thread, validate arguments against closed lists, call `done` once) and register it: `GadgetToolDispatcher.shared.register(runner, for: [.<gadget>])` in `wireNachoComboMCP()` (one line; mention it in your PR). Use `PetCommandOutcome.gadgetOff / .permissionNeeded` for the shared results.
4. Write the gadget's `guide` (and `prompts` for frequent flows) in the same file.
5. Run `swift test`: `GadgetRegistryTests.testRegistryKeepsTheContract` must stay green (names, words, lengths, schema, guide examples). Add your own tests (runner parameters, results).
6. Connector: nothing else to do — the capability is declared from the registry with the approval of its risk. MCP: nothing else to do — the tool is listed under your gadget switch.
7. Never log or post clipboard text, screen contents, typed text, keys.
