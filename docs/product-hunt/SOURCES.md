# Sources, unverified items and claim evidence

Check date for all official sources: **2026-11-21**. Repository base: `origin/main` at the commit recorded in
[README.md](README.md) (the README of that commit is the feature source). Line numbers refer to that commit.

## A. Official sources checked

All pages were opened and read on 2026-11-21 (the text was read, not recalled). The old `producthunt.com/launch/*` URLs
answer with a redirect to the help center.

| # | Title | URL | Checked | What it confirmed |
|---|---|---|---|---|
| A1 | Launch Guide (collection) | https://help.producthunt.com/en/collections/19793093-launch-guide | 2026-11-21 | Index of the 8 articles; `producthunt.com/launch` redirects here |
| A2 | 2. What kind of products get featured | https://help.producthunt.com/en/articles/17734341-2-what-kind-of-products-get-featured | 2026-11-21 | It must be a product people can try; new or major update; trustworthy maker; featuring is editorial |
| A3 | 3. Set your goals and pick your launch date | https://help.producthunt.com/en/articles/17734355-3-set-your-goals-and-pick-your-launch-date | 2026-11-21 | Live at 12:01 AM Pacific; schedule from tomorrow up to 30 days ahead; 2 launches per person per day; date can change |
| A4 | 4. Build your product page | https://help.producthunt.com/en/articles/17834537-4-build-your-product-page | 2026-11-21 | Name 40, tagline 60, description 500 characters; up to 3 launch tags; logo 240x240 JPG/PNG/GIF up to 2 MB; gallery at least 1, recommended 1270x760; video by link; pricing Free/Paid/Free options; open source field; makers; maker comment up to 5,000 characters; Create draft vs Schedule launch; "Before you schedule" checklist |
| A5 | 5. How to promote your launch and what to avoid | https://help.producthunt.com/en/articles/17734384-5-how-to-promote-your-launch-and-what-to-avoid | 2026-11-21 | Never ask for upvotes; no paid or fake engagement; no spam; prepare posts before the day; badge |
| A6 | 6. What to do during and after your launch | https://help.producthunt.com/en/articles/17734397-6-what-to-do-during-and-after-your-launch | 2026-11-21 | Answer every comment in near real time; team coverage; dashboard; after-launch follow-up; award badge |
| A7 | 8. Launch FAQ and myths | https://help.producthunt.com/en/articles/17734646-8-launch-faq-and-myths | 2026-11-21 | Personal accounts only; submission requirements; hunting your own product is fine; relaunch after two months |
| A8 | Community Guidelines (updated April 11, 2025) | https://help.producthunt.com/en/articles/3615694-community-guidelines | 2026-11-21 | Profiles must represent an individual; spam, bots, asking for upvotes are removal reasons |
| A9 | Launch tags (topics) | https://www.producthunt.com/topics | 2026-11-21 | Topics are called "launch tags"; list exists |
| A10 | Topic pages | https://www.producthunt.com/topics/mac , `/productivity` , `/developer-tools` , `/open-source` , `/menu-bar-apps` | 2026-11-21 | All five load with exactly these titles: Mac, Productivity, Developer Tools, Open Source, Menu Bar Apps |
| A11 | NachoCombo for Windows README | https://github.com/mafianacho/nachocombo-windows | 2026-11-21 | Public repository, MIT badge, Windows 10 and 11 badge, own README |

How these were read: the official pages were fetched with a web-fetch tool and the quoted rules were copied from the page
text; the Launch Guide pages are marked "Updated over 2 weeks ago" without an exact date.

## B. Not verified (items to settle before relying on them)

| # | Item | Why it is open | Where it shows |
|---|---|---|---|
| B1 | Maximum number of gallery images; gallery image formats and file size; GIF size for the gallery; video length, format and hosts | G4 does not state them (only logo limits and the 1270x760 recommendation) | ASSETS.md, PROCEDURE.md section 2 |
| B2 | A "platform" field (macOS) on the product form; whether "macOS" is a launch tag (no: `/topics/macos` is a 404, "Mac" exists) | Not described in the guides; the form itself was not opened (opening it needs an account, which is not approved) | PROCEDURE.md, LISTING.md |
| B3 | README says Nacho Pet "connects to nothing until you open the chat" (README, Nacho Pet section); the code downloads the character pictures from the Nacho server at pet start and when the app becomes active (C31). README and code differ slightly. The listing states the code's behavior. A fix to the README is the code owner's call (NACHO-856 owns the README now) | Found while checking claims; not changed here | LISTING.md FAQ 2 |
| B4 | "No analytics or tracking" is not claimed as a fact. What was done: all `URLSession` uses in `Sources/` were listed (update check, public IP lookup, Nacho Pet servers, update CLI). This search cannot prove that nothing else sends data (for example through a dependency; `Package.swift` lists no external package dependency) | Absence cannot be proven | LISTING.md FAQ 2 |
| B5 | Best day and time to launch; which subreddits or communities allow self-promotion; X account to post from | Not in Product Hunt's guides; a business decision | PROCEDURE.md, LISTING.md section 5 |
| B6 | Whether an account must be some days old before launching; edits to the page after launch; notification timing to followers | Not stated in the articles read | PROCEDURE.md |
| B7 | Whether the link was launched on Product Hunt before (relaunch rule) | Product Hunt search was not used; no account | PROCEDURE.md section 0 |
| B8 | Features, state and release status of the Windows project | Only its README header was read; nothing was run | LISTING.md FAQ 6 |
| B9 | Whether the v0.13.0 release (tag, GitHub Release) exists | Resolved at review on 2026-11-21: `gh release view v0.13.0` shows it published (not draft, not pre-release) at 2026-11-21T06:08:23Z, so it is now the latest release; at the time of writing it was not yet out. At base `fdcd4c9` (PR #76 merged) the README, release notes and `scripts/build-app.sh` default say 0.13.0. The gallery and video must use a v0.13.0 build; re-read README and `Resources/WhatsNew` before the PR is marked ready | LISTING.md, ASSETS.md |
| B10 | Official English caption length limit for gallery images | No such field described | ASSETS.md |
| B11 | Whether the Korean-only UI hurts reception on Product Hunt | An opinion, not a fact; the boss decides about localization (out of scope) | LISTING.md FAQ 6 |

## C. Claim evidence table (LISTING.md claim → README section or code path)

README section names are headings of `README.md`; `README:NNN` is the start line of that section at the base commit.

| Id | Claim in LISTING.md | Evidence |
|---|---|---|
| C1 | Product name "Nacho Combo" | README title; `NOTICE:1`; `TRADEMARKS.md` |
| C2 | Repository and Releases links | README top line (releases/latest link); Install section README:628 |
| C3 | Free, MIT, open source | README top line "free and open source (MIT)"; `LICENSE:1` ("MIT License") and its scope note |
| C4 | MIT covers source only; art, icon, names excluded; ™ not ® | `LICENSE:3-5`; `NOTICE:3-8`; `TRADEMARKS.md` ("none of them is a registered trademark (®) yet"); `Resources/Nacho/LICENSE:1-6` |
| C5 | macOS 12 or later; Apple Silicon and Intel (universal) | README top line; Install section README:628; `Package.swift:31` (`.macOS(.v12)`); `scripts/build-app.sh:5,16` (`UNIVERSAL=1` builds arm64 + x86_64); `scripts/build-app.sh:71` (`LSMinimumSystemVersion` 12.0) |
| C6 | 13 gadgets, each its own switch; Computer Use and Nacho Pet are named separately as experimental (see C42) | README intro paragraph; Gadgets table README:152 |
| C7 | Snap windows from the keyboard | Window Snap, README:266 |
| C8 | Watch CPU, memory, disk, network in the menu bar | System Monitor, README:188 |
| C9 | Park files on a floating shelf | File Shelf, README:289 |
| C10 | Keep screen captures floating above work | Capture Float, README:305 |
| C11 | Dim everything behind the window you work in | Focus Dim, README:328 |
| C12 | Keep the Mac awake | Keep Awake, README:344 |
| C13 | Search clipboard history | Clipboard History, README:354 |
| C14 | Switch sound and microphone devices | Device Control, README:365 |
| C15 | Move between windows with ⌥Tab | App Switch, README:376 |
| C16 | Tune a wheel mouse | Mouse Tune, README:386 |
| C17 | Clock with a calendar | Calendar Clock, README:395 |
| C18 | See what fills your disk | Disk Map, README:405 |
| C19 | Menu bar organizer (folds icons away) | Menu Bar Organizer, README:171 |
| C20 | Widget window; settings in a panel on the right | README "The settings panel" README:57 (intro paragraph also says there is no separate settings window) |
| C21 | App screens in Korean; English UI not in this release | Brief for NACHO-975 (boss-approved assumption); README itself shows Korean labels (for example `설정 (Settings)` tabs, README:57 section). No English localization exists in the README feature list. |
| C22 | Ad-hoc signed, not notarized; right-click ▸ Open | README Usage step 1 (README:42); Install section README:628; `scripts/build-app.sh:96,98` (`codesign --sign -`) |
| C23 | Computer Use and Pet "not yet tried on a real Mac" | README Computer Use callout (README:437) and Nacho Pet callout (README:461) |
| C24 | Nothing asked before a gadget is switched on; sheet, then macOS dialog | README "Permissions" README:126, steps 1 |
| C25 | Accessibility: Window Snap, App Switch, Mouse Tune; keystrokes never read | README:126; Mouse Tune README:386 ("keystrokes are never read"); Window Snap README:266; App Switch README:376 |
| C26 | Screen Recording: Capture Float | README:126; Capture Float README:305 ("Nothing is recorded or uploaded") |
| C27 | Optional permissions: Clipboard History paste, Calendars, Notifications, Full Disk Access | README:126 |
| C28 | Pet microphone and speech recognition permission only when dictating | `scripts/build-app.sh:84-85` (usage descriptions); README Nacho Pet "Hold to talk" and "Dictation" bullets |
| C29 | Update check at launch and every 6 hours via GitHub; automatic install default on; checksum verified; both can be switched off | README Updates README:638-643; `Sources/NachoCombo/UpdateController.swift:36` (`api.github.com/repos/mafianacho/nachocombo/releases/latest`), `:164,170` (hourly timer asks whether a check is due); `Sources/NachoComboCore/Updates.swift:234` (`checkInterval` = 6 hours); `Sources/NachoComboCore/Settings.swift:71,133` (defaults true) |
| C30 | Public IP lookup off by default, via Cloudflare | README System Monitor ("The public IP is an external request … OFF by default"); `Sources/NachoCombo/MonitorEngine.swift:92,111,441` |
| C31 | Pet on by default; downloads character pictures from the Nacho server (default `nacho.nachotown.com`) at start and when the app becomes active, without a token; chat later | `Sources/NachoComboCore/Modules.swift:55` (`enabledByDefault` is only `.nachoPet`); `Sources/NachoComboCore/Settings.swift:58`; `Sources/NachoCombo/Pet/NachoPetModule.swift:99` (start of `PetServerArt`); `Sources/NachoCombo/Pet/PetPlatform.swift:225-262` (sync at start and on `didBecomeActive`); `Sources/NachoComboCore/Pet/PetCharacterAssets.swift:84` (`bearer: nil`); `Sources/NachoComboCore/Pet/PetSettings.swift:52` (production URL). README Nacho Pet section for the "hide closes every connection" part |
| C32 | Login in the system browser with PKCE, password never seen, Keychain | README Nacho Pet "Account" bullet; `Sources/NachoComboCore/Pet/PetAuth.swift:3`; `Sources/NachoComboCore/Pet/PetSettings.swift:53` (`auth.mafianacho.com`) |
| C33 | Computer Use: off by default, `127.0.0.1` only, optional LAN over TLS only | README Computer Use bullets README:437; `Sources/NachoCombo/ComputerUseCard.swift:182` |
| C34 | Open at Login needs macOS 13; recording needs macOS 12.3 | README Usage step 5 (README:42) and Capture Float "Record"; `Sources/NachoCombo/CaptureRecording.swift:8,10`; `Sources/NachoCombo/AppDelegate.swift:1292` (`#available(macOS 13.0, *)`) |
| C35 | Signature changes with updates; permission list after update | README Permissions step 5 (README:126) and Updates (README:638) |
| C36 | `SHA256SUMS.txt` and `shasum` check | README Install README:628 |
| C37 | Windows: separate public repo, Windows 10 and 11, MIT | `https://github.com/mafianacho/nachocombo-windows` README header (A11); not tested (B8) |
| C38 | Server errors shown in Korean | README Nacho Pet "Credits" bullet |
| C39 | Computer Use details (client with key, tool groups, high-risk groups, emergency stop ⌃⌥⌘.) | README Computer Use README:437; `Sources/NachoCombo/ComputerUseModule.swift:25` (`⌃⌥⌘.`) |
| C40 | Pet details (chat, dictation, capture and shelf handoff, window and gadget commands switchable off, phone-only items) | README Nacho Pet README:461 |
| C41 | Combos (preset switches) | README "Combos" README:91 |
| C42 | 13 gadgets + experimental Computer Use (MCP server, off by default) + Nacho Pet; the v0.13.0 widget window shows all 15 tiles, so LISTING says "13 gadgets" and names the other two as experimental, never "15 gadgets" | README intro; brief for NACHO-975 |

Claims in LISTING.md with no row above are opinions or process statements and carry no feature claim (the "Who it is
for" line and the "what I'd love to hear" line).
