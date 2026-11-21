# Product Hunt listing content (English)

Status: DRAFT. Every sentence with a feature or spec is traced to the README or the code in
[SOURCES.md](SOURCES.md) (section C, claim ids `C1`, `C2`, ...). Nothing here has been posted or sent.
Base: `origin/main` README at the time of writing (see SOURCES.md for the commit).

Facts used throughout: 13 gadgets + experimental Computer Use + Nacho Pet; macOS 12 or later; Apple Silicon and Intel;
source under the MIT license; app ad-hoc signed and not notarized. App screens are in Korean; English UI is out of scope
for this release.

## 1. Product fields

| Field | Value | Claim |
|---|---|---|
| Name (max 40) | `Nacho Combo` (11 characters) | C1 |
| Link | https://github.com/mafianacho/nachocombo | C2 |
| Releases | https://github.com/mafianacho/nachocombo/releases | C2 |
| Pricing | Free | C3 |
| Open source | Yes, MIT (source code only; see FAQ 5 for what MIT does not cover) | C3, C4 |
| Platform | macOS 12 (Monterey) or later; Apple Silicon and Intel (universal binary) | C5 |
| Launch tags (max 3 can be chosen) | Candidates, all confirmed to exist on https://www.producthunt.com/topics on 2026-11-21: **Mac**, **Menu Bar Apps**, **Open Source**, **Developer Tools**, **Productivity**. Suggested three: Mac, Menu Bar Apps, Productivity (Open Source is already covered by the open-source field). | SOURCES B/A |

## 2. Tagline candidates (max 60 characters)

<!-- len:tagline_1:60 -->
> Mac menu bar gadgets in one free open-source app

<!-- len:tagline_2:60 -->
> Window snap, clipboard, monitor and more, one menu bar app

<!-- len:tagline_3:60 -->
> Switch on only the Mac tools you need, one at a time

## 3. Description candidates (max 260 characters)

<!-- len:descr_1:260 -->
> Nacho Combo is a free, open-source macOS menu bar app with 13 gadgets, each its own switch: window snap, system monitor, file shelf, clipboard history, disk map and more. Plus experimental Computer Use and Nacho Pet. macOS 12+.

<!-- len:descr_2:260 -->
> One menu bar app instead of a pile of small Mac utilities. Every gadget is its own switch, and macOS permissions are asked only when you switch on a gadget that needs one. Free, MIT-licensed source, macOS 12 or later, Apple Silicon and Intel.

### Character counts (script output)

Run `python3 docs/product-hunt/check_lengths.py`. Output recorded when this file was last edited:

```text
key            chars  limit  ok
tagline_1         48     60  OK
tagline_2         58     60  OK
tagline_3         52     60  OK
descr_1          227    260  OK
descr_2          242    260  OK
```

(The script is the source of truth. Product Hunt's own limits are 60 for the tagline and 500 for the description: G4 in PROCEDURE.md. The 260 limit is the
stricter limit set in the task brief.)

## 4. Maker first comment (draft; up to 5,000 characters allowed)

> Hi Product Hunt! I'm one of the makers of Nacho Combo.
>
> **Why we built it:** a Mac menu bar fills up with small utilities, each with its own settings and its own permission
> prompts. Nacho Combo puts 13 of them in one app (plus an experimental Computer Use server and Nacho Pet), and every gadget is its own switch, so you only turn on what you
> use. (C6)
>
> **What it does:** snap windows from the keyboard, watch CPU, memory, disk and network in the menu bar, park files on a
> floating shelf, keep screen captures floating above your work, dim everything behind the window you work in, keep
> the Mac awake, search your clipboard history, switch sound and microphone devices, move between windows with ⌥Tab,
> tune a wheel mouse, show a clock with a calendar, and see what fills your disk. You can also order a preset "combo" that
> switches on a few gadgets together. (C7 to C19)
>
> **How it is set up:** the app opens a widget window with every gadget as a widget; click one and its settings open in a
> panel on the right. (C20)
>
> **Who it is for:** Mac users who like keyboard shortcuts and small tools but not ten separate apps. (opinion, not a claim)
>
> **Good to know, honestly:**
> - The app screens are in Korean for now; an English interface is not part of this release. (C21)
> - The app is ad-hoc signed and not notarized, so macOS blocks the first launch: right-click the app, choose Open, then
>   Open. (C22)
> - Computer Use (an experimental local MCP server, off by default) and Nacho Pet have not yet been tried on a real Mac
>   according to the README. (C23)
> - The source is MIT-licensed. The Nacho character art, the app icon and the names are not open source. (C4)
>
> **What I'd love to hear:** which gadget you would use first, and what is missing. Feedback and bug reports are
> welcome in the GitHub repository: https://github.com/mafianacho/nachocombo

(No upvote request, per Product Hunt's rule: G4/G5 in PROCEDURE.md. 🔒 Boss approval required before posting.)

## 5. Launch-day announcement drafts (DRAFTS ONLY, NOT SENT)

Rules for all of them: do not ask for upvotes or reward them (G5); send only where the poster already takes part
(G5); each community has its own self-promotion rules, which I did not verify (`⚠ Unverified`): check them first.
Replace `<PH-LINK>` with the launch URL on the day. 🔒 Boss approval required for every send.

### 5.1 X post (≤280 characters)

> We just launched Nacho Combo on Product Hunt: one free, open-source Mac menu bar app with 13 gadgets (window snap, file shelf, clipboard history and more), each its own switch, plus experimental Computer Use and Nacho Pet. Feedback welcome: <PH-LINK>

### 5.2 Reddit post (for a Mac-app community; `⚠ Unverified`: which subreddit allows self-promotion and in what form)

> **Title:** I built a free, open-source menu bar app that bundles 13 small Mac tools
>
> Nacho Combo is a macOS menu bar app (macOS 12+, Apple Silicon and Intel, MIT source). Gadgets include window snapping,
> a system monitor, a file shelf, floating screen captures, clipboard history, device control, an app and window
> switcher, mouse tuning, a calendar clock, a disk map and a menu bar organizer. Each one is a separate switch. The app also has two experimental extras, Computer Use (an MCP server, off by default) and Nacho Pet, which have not been tried on a real Mac yet.
>
> Things to know: the UI is in Korean for now, and the app is ad-hoc signed and not notarized, so the first launch needs
> right-click ▸ Open. Source and downloads: https://github.com/mafianacho/nachocombo . We are on Product Hunt today
> as well: <PH-LINK> . I would like to hear which gadget you would use and what is missing.

### 5.3 Short community or chat message (Discord, Slack, newsletter)

> Nacho Combo, a free open-source macOS menu bar app with 13 gadgets (window snap, monitor, file shelf, clipboard
> history and more; plus experimental Computer Use and Nacho Pet), is on Product Hunt today: <PH-LINK> . The UI is Korean for now. Honest feedback is the most
> useful thing you can give.

## 6. FAQ (7 entries; for the Product Hunt page, the repository and replies)

### FAQ 1. Which permissions does it need, and which gadget uses what?

Four gadgets need a macOS permission, and nothing is asked before you switch the gadget on (C24):

| Permission | Gadgets | Why |
|---|---|---|
| Accessibility | Window Snap, App Switch, Mouse Tune | read and change other apps' window frames, list and raise windows, change a mouse's events (keystrokes are never read) (C25) |
| Screen Recording | Capture Float | read the pixels of the area you select (C26) |

Optional: Accessibility lets Clipboard History paste for you (otherwise it copies), Calendars lets Calendar Clock show
your events (read on the Mac, not sent), Notifications are for System Monitor alerts, and Full Disk Access lets Disk Map
see every folder at once (C27). Nacho Pet's microphone and speech recognition permissions are asked only when you
dictate or hold Nacho to talk (C28). Switching on a gadget that needs a permission shows a short sheet first, then
macOS's own dialog (C24).

### FAQ 2. What does it send over the network? Is my data private?

Facts checked in the code (paths in SOURCES.md, C29 to C33):
- **Gadgets work on the Mac.** For example Capture Float: "Nothing is recorded or uploaded"; Disk Map "reads names and
  sizes on this Mac and nothing leaves it"; Calendar events "never sent anywhere" (README).
- **Update check (on by default):** at launch and every 6 hours the app asks the GitHub API for the latest release of the
  public repository; with Install Automatically on (default) a new version is downloaded, checked against the release's
  `SHA256SUMS.txt` and installed when the app quits. Both can be switched off in General. A failed check stays quiet. (C29)
- **Public IP lookup (System Monitor, off by default):** only from a button or if you turn auto lookup on; it contacts
  `https://www.cloudflare.com/cdn-cgi/trace`. (C30)
- **Nacho Pet (on by default):** the pet needs no permission. The README says it "connects to nothing until you open the
  chat". The code also downloads the pet's character pictures from the Nacho server (default `nacho.nachotown.com`) when
  the pet starts and when the app comes to the front, with a plain request that carries no account token. Chat, login and
  other server calls start only when you use them. You can switch the pet gadget off, which hides it and closes every
  connection. (C31) ⚠ The README sentence and the code differ slightly: see SOURCES.md section B, item B3.
- **Nacho account login:** opens `auth.mafianacho.com` in a system browser sheet (PKCE); the app never sees the
  password and keeps the session in the macOS Keychain. (C32)
- **Computer Use (off by default):** the server listens on `127.0.0.1` only; an optional LAN mode uses TLS only. (C33)
- No analytics or tracking SDK was found by searching the sources for network calls (SOURCES.md, section B, item B4 says
  how the search was done and what it cannot prove).

### FAQ 3. Is it really free? What is the license?

Yes. The download is free and the source code is under the MIT license (C3). The license covers the source code only.
The Nacho character pictures (`Resources/Nacho/`), the app icon and logo, and the names Nacho Combo™, Nacho™ and
Mafianacho™ are not open source and are not under MIT (C4). None of the names is a registered trademark yet (C4).

### FAQ 4. Which macOS versions and Macs are supported?

macOS 12 (Monterey) or later on Apple Silicon and Intel (universal binary) (C5). A few features need newer macOS:
Open at Login needs macOS 13 or later, and Capture Float's screen recording needs macOS 12.3 or later (C34).

### FAQ 5. Why does macOS block the first launch? Is it signed?

The app is ad-hoc signed and not notarized, with no Apple Developer ID signature. Gatekeeper blocks the first launch:
right-click the app ▸ Open ▸ Open, or allow it in System Settings ▸ Privacy & Security (C22). Each update changes the
signature, so macOS may ask again for Accessibility and Screen Recording, and the app lists what lost its permission
(C35). Downloads come with `SHA256SUMS.txt` so you can verify them with `shasum -a 256 -c SHA256SUMS.txt` (C36).

### FAQ 6. Is there a Windows version? Is the app in English?

- **Windows:** this listing is for the macOS app. A separate public repository, `mafianacho/nachocombo-windows`
  (https://github.com/mafianacho/nachocombo-windows), describes itself as "NachoCombo for Windows" for Windows 10 and 11
  with an MIT license (C37). Its feature list, behavior and release state were not tested for this document: treat its
  own README as the source.
- **Language:** the app's screens contain Korean text today, and an English interface is not part of this release
  (C21). Captions on the Product Hunt gallery images are in English; the app screens in them are not translated. Nacho
  Pet's server error messages are shown in Korean (C38).

### FAQ 7. What are Computer Use (experimental) and Nacho Pet?

- **Computer Use (experimental):** an MCP server inside the app. A client (an AI agent or a script) that holds a key made
  in the app can look at the screen, open apps, move windows, click and type, and use the clipboard, but only through
  tool groups you switched on. Off by default, every tool group is off, high-risk tools (AppleScript, shell commands,
  files, force quit) are separate groups with a confirmation, emergency stop is ⌃⌥⌘. . The README says it has not yet been
  tried on a real Mac. (C39)
- **Nacho Pet:** the Nacho character in the bottom-right corner of the screen, on by default. Click it to chat (needs a
  Nacho account), dictate, attach a capture or a shelf file, or ask it to arrange windows, switch gadgets, change the
  volume and similar tasks on this Mac; these can be switched off in its settings. Voice calls, buying credits and
  card login stay in the phone app. The README says the macOS part has not yet been tried on a real Mac. (C40)

## 7. Trademark and artwork notes (for whoever uploads)

- Using the app icon as the Product Hunt logo and showing the Nacho character in screenshots is the official publisher
  (Mafianacho) showing its own app, which `TRADEMARKS.md` allows ("Using the official app as published by Mafianacho,
  including the character inside it"). It must not look like someone else's endorsement.
- Do not hand the character pictures out as stand-alone images or stickers (TRADEMARKS.md). Gallery images show the
  app, not loose character art.
- Write the names as `Nacho Combo` in text; use the ™ mark where the repository does if the boss wants it. No ®.
