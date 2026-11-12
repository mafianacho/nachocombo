# Selection bar ↔ Nacho Pet (design draft, web mockup first)

A PopClip-like bar for text selected in any app, part of **Nacho Pet** (no separate gadget). Scenes:
`design/web/index.html?scene=sel-…` (`sel-bar`, `sel-more`, `sel-ask`, `sel-preview`, `sel-long`, `sel-stream`,
`sel-result`, `sel-secure`, `sel-intro`, `sel-settings`). No server change.

Native (AppKit): rules in `Sources/NachoComboCore/Pet/PetSelection.swift` (Linux tests
`Tests/NachoComboCoreTests/PetSelectionTests.swift`), screen in `Sources/NachoCombo/Pet/PetSelection*.swift` and
`NachoPetModule+Selection.swift`, off-screen captures in `Tests/NachoComboAppTests/SelectionCaptureTests.swift`.

## Flow
1. Text is selected (mouse up or ⇧-arrow selection ends). After `motion.selectBarDelay` (default 300 ms; or only with ⌘
   held, a setting) the bar appears `size.selectBarOffset` above the selection (below it when there is no room).
   It goes away on Esc, a click elsewhere, typing, scrolling or a new selection.
2. Buttons: 복사 · 검색 · 번역 · 요약 · 설명 | 나초에게 묻기 · ⋯. Copy and Search act locally: Copy puts the text on the
   pasteboard, and Search opens the default browser with the selection as a **Google** query (Settings: Naver or
   DuckDuckGo). They send nothing to Nacho.
3. 번역 / 요약 / 설명 / 나초에게 묻기 (a one-line question; its key hint "↩ 확인 · esc" sits inside the bar) open the pet's chat with a **preview card**. It lists
   every context item with its own "빼기", plus 보내기 / 취소. Nothing leaves the Mac before 보내기.
4. After 보내기 the answer streams in the chat as usual. The sent turn shows a chip ("Safari · 고른 글 129자 · 맥락 4개"),
   and "보낸 내용 보기" reopens the list. Answers get 복사 · 다시 actions.
5. ⋯: "<앱>에서는 띄우지 않기" (adds the app to the exclusions), "잠시 끄기 (1시간)", "선택 동작 바 설정…".

## Context sent (structured, not mixed into the prompt)
The message text is only the instruction ("번역해 줘 · 한국어로", or the user's question). The context goes as **one
text attachment** (`선택 맥락.md`, `text/markdown`). It uses the existing `POST /api/v1/media/uploads` and
`attachments: [{attachment_id}]` path, which the server already reads for `text/*`, so the server does not change.

| Field | Source | Limit |
|---|---|---|
| selected text | AX `kAXSelectedTextAttribute` of the focused element | 8,000 chars |
| app name, bundle id | `NSWorkspace.frontmostApplication` | — |
| window title | AX title of the focused window | 200 chars |
| URL, page title | browsers only (Safari, Chrome, Arc, Edge, Firefox, Brave, Vivaldi, Opera), `AXURL` of the web area or the window's `AXDocument`; none when unavailable. Query, fragment and user info are dropped (they can hold sign-in tokens) | 500 chars |
| text before / after | AX `kAXStringForRangeParameterizedAttribute` around the selected range | 400 chars each side |
| language (guess) | `NLLanguageRecognizer` on the selection | — |

Each row can be removed in the preview. Removed rows are not uploaded. When the selection is longer than the
limit, the preview says so ("너무 길어서 앞 8,000자만 보내요") and only the first 8,000 characters are sent. The defaults for which rows are on are a
setting later; for now all are on.

## Privacy and safety
- Before a button is pressed, nothing is sent and nothing is stored. The selection is read only to decide whether to
  show the bar and to fill the preview.
- No bar in password fields (`AXSecureTextField` / subrole), while **secure input** is on (`IsSecureEventInputEnabled`),
  or in excluded apps. The built-in exclusions are 1Password, Bitwarden, Keychain Access, Passwords and System Settings,
  plus terminals (Terminal, iTerm, Warp: they often show keys), which the user can allow one by one. The user can add
  more apps and remove only the ones they added. Banking sites cannot be told apart by app (no URL filter): users who
  want that add the browser.
- Selected text, context and answers are never written to logs or diagnostics (only counts and lengths). The
  capture, context, rows and sent request print and dump without their text (tested).
- The order is fixed in `PetSelectionReader`: probe (app, role, secure input) → gate → only then read the text.
  A password field, secure input, an excluded app or Nacho Combo's own windows are never read.
- The attachment starts with a line telling Nacho the text is material, not instructions to follow.
- Accessibility is needed to read the selection. It is asked only when the user switches the bar on (from the
  first-use card or Settings), never at launch.

## Settings (Nacho Pet card ▸ Selection Bar)
On/off (default **off**; the first-use card in the chat offers to switch it on), button order and visibility (Ask
Nacho always shown), delay (0.3 s default; 0 / 0.6 s / only with ⌘), search engine (Google default; Naver,
DuckDuckGo), excluded apps. The settings page of the app is narrower (488 pt) than the mockup, so the two columns
stack there.

## Pet badges (changed in the mockup with this draft)
The pet shows a badge only where the face alone cannot say it: dictation (red mic, only while really dictating),
thinking (dots), dozing (z). Each has its meaning as tooltip and accessibility label. The "answering" badge was removed,
because the chat header already says it (native too).

## Tokens added
`size.selectBarHeight`, `selectBarIcon`, `selectBarOffset`, `selectAskWidth`, `contextRowIcon`, `radius.selectBar`,
`motion.selectBarDelay`, `motion.selectBarFade`. The host app's selection highlight in the mockup (#B4D5FE /
#3F638B) is content, not a token.
