# Product Hunt launch kit for Nacho Combo

Everything needed to prepare a Product Hunt launch, **up to the point just before publishing**. This folder is documents
only. No Product Hunt account was created or connected, and nothing was saved, uploaded, scheduled, posted or sent.
Written in English for Product Hunt; ticket NACHO-975 (sub-issue NACHO-980).

Base: `origin/main` at `fdcd4c9` (PR #76, v0.13.0 notes and README pictures merged; README says 13 gadgets, plus the
experimental Computer Use and Nacho Pet). The v0.13.0 GitHub Release was published on 2026-11-21 (06:08 UTC, tag
`v0.13.0`), so the gallery and video must use a v0.13.0 build. Re-read the README and `Resources/WhatsNew` before the launch.

## Files

| File | What it holds |
|---|---|
| [PROCEDURE.md](PROCEDURE.md) | Step by step: account, product page fields, makers, date and time (00:01 Pacific), launch day, after launch. Each step marks 🔒 where boss approval is required. Official rules with links and check dates |
| [LISTING.md](LISTING.md) | Name, 3 taglines (60 characters or fewer), 2 descriptions (260 or fewer), launch tags, links, price and platform, maker first comment, announcement drafts (not sent), 7 FAQ entries |
| [ASSETS.md](ASSETS.md) | Logo, 5 to 8 gallery images (title, caption, app screen, size), video link slot, specs |
| [SOURCES.md](SOURCES.md) | Official sources with check dates, list of unverified items, claim-to-evidence table |
| [check_lengths.py](check_lengths.py) | Counts the characters of the tagline and description candidates (`python3 docs/product-hunt/check_lengths.py`) |

## Boss approval points

Nobody should do these without a direct yes from a boss (one yes per item):

1. Creating or connecting a Product Hunt account, and naming who launches and who is credited as a maker
2. Saving the product page (even as a draft) with the final texts
3. Uploading the logo, gallery images and the video, and publishing the video on any host
4. Choosing the launch date and **scheduling** the launch (this makes it go public by itself at 00:01 Pacific)
5. Posting the maker comment and any reply on Product Hunt
6. Sending the announcement to X, Reddit or any community
7. Merging this pull request, and any change to the README, release or app (out of scope here)

Also open for the boss: how to handle the Korean-only app screens on an English platform (English localization is out of
scope of this ticket), and the README sentence about Nacho Pet's network use (SOURCES.md, B3).

## Status of each item

| Item | Status | Waiting for |
|---|---|---|
| Procedure | Draft | Boss review; re-read the official articles before each 🔒 step |
| Name, link, price, platform | Draft | Boss review |
| Taglines (3) | Draft | Boss picks one |
| Descriptions (2) | Draft | Boss picks one |
| Launch tags | Draft | Boss picks up to 3 (all candidates verified to exist) |
| Maker first comment | Draft | Boss review; makers to be named |
| Announcement drafts (X, Reddit, chat) | Draft (not sent) | Boss approval to send |
| FAQ (7) | Draft | Boss review; B3 in SOURCES.md |
| Logo (240x240) | Waiting for image | Image step |
| Gallery images (5 to 8) | Waiting for image | v0.13.0 screens from the image step |
| Intro video | Waiting for video | Video step (separate NACHO-975 sub-issue); link slot `TBD after boss-approved upload` |
| Unverified list | Open | See SOURCES.md section B |

## Privacy rule for everything in this folder

No real user names, e-mail addresses, file or folder paths, hostnames, clipboard text, calendar events or tokens. Sample
data only. Images and video follow the same rule.
