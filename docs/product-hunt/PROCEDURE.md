# Product Hunt launch procedure for Nacho Combo

Status: DRAFT for boss review. Nothing here has been done: no account was created or connected, no page was saved,
nothing was uploaded, scheduled, posted or sent.

Rule source: Product Hunt's own Launch Guide (help center), read on **2026-11-21**. Product Hunt changes its rules, so
re-read the linked article before each step marked 🔒 and fix this file if it differs. Values I could not confirm are
marked `⚠ Unverified (estimate)`. All sources are listed in [SOURCES.md](SOURCES.md).

Legend: 🔒 **Boss approval required** = a person with authority must say yes before the step happens (one approval per
step; approval for one step is not approval for the next).

Short names for the official articles (all under `https://help.producthunt.com/en/`):

| Short | Article | URL |
|---|---|---|
| G2 | 2. What kind of products get featured | https://help.producthunt.com/en/articles/17734341-2-what-kind-of-products-get-featured |
| G3 | 3. Set your goals and pick your launch date | https://help.producthunt.com/en/articles/17734355-3-set-your-goals-and-pick-your-launch-date |
| G4 | 4. Build your product page | https://help.producthunt.com/en/articles/17834537-4-build-your-product-page |
| G5 | 5. How to promote your launch and what to avoid | https://help.producthunt.com/en/articles/17734384-5-how-to-promote-your-launch-and-what-to-avoid |
| G6 | 6. What to do during and after your launch | https://help.producthunt.com/en/articles/17734397-6-what-to-do-during-and-after-your-launch |
| G8 | 8. Launch FAQ and myths | https://help.producthunt.com/en/articles/17734646-8-launch-faq-and-myths |
| CG | Community Guidelines | https://help.producthunt.com/en/articles/3615694-community-guidelines |
| TOP | Launch tags (topics) list | https://www.producthunt.com/topics |

(The old `producthunt.com/launch` URLs redirect to the Launch Guide collection:
https://help.producthunt.com/en/collections/19793093-launch-guide.)

## 0. Fit check (before anything else)

| Check | Result for Nacho Combo | Source |
|---|---|---|
| It is a product, not content about one | Yes: a downloadable macOS app | G2 (checked 2026-11-21) |
| People can try it | Yes: public download on GitHub Releases | G2 |
| It is new or has a major update | ⚠ Unverified: the app has existing releases; decide what is "new" for this launch (for example the v0.13.0 widget window with the settings panel on the right) | G2 |
| Relaunch | Not known if the link was launched in the last two months; Product Hunt asks for a relaunch request in that case | G4, G8 |
| Company account not allowed | Launch from a **personal** account of a real maker; never a company or brand account | G8, CG |

## 1. Account preparation

| # | Step | Detail | Approval |
|---|---|---|---|
| 1.1 | Pick the launching person | One real person per account; the account must "appear human and represent an individual, not a company" (CG, G5, G8). | 🔒 Boss approval required (who) |
| 1.2 | Create or choose the personal Product Hunt account | Verified email address required (G8). Do it **well before** launch day (G4: co-makers "should create their accounts well before launch day"). ⚠ Unverified: how long an account must exist before it can launch; the guides read do not say. | 🔒 Boss approval required (create / connect an account) |
| 1.3 | Fill in the profile | Real name, photo, short bio. No fake or extra accounts (G5). | 🔒 Boss approval required |
| 1.4 | Co-makers make their own accounts | So they are credited and can reply to comments (G4). | 🔒 Boss approval required (who is a maker) |
| 1.5 | Prepare the files | Logo, gallery images and video from [ASSETS.md](ASSETS.md); texts from [LISTING.md](LISTING.md). | none (local files only) |
| 1.6 | Check the download works | Release page opens, the .dmg downloads, the first-launch steps (right-click ▸ Open) are on the page. G4 checklist: "Product works in production". | none |

## 2. Product page (field by field)

Entry point (G4): sign in with the personal account and click **Submit** at the top right of any page. Saving a draft
("Create draft") keeps the page in draft mode: "Nothing goes live, and our team doesn't review drafts" (G4).

| Field | Rule (official) | Our value | Approval |
|---|---|---|---|
| Product link | "a direct link to where people can use or download it: your homepage, an app store page, or a GitHub repo" (G4) | `https://github.com/mafianacho/nachocombo` (Releases page: `https://github.com/mafianacho/nachocombo/releases`) | 🔒 Boss approval required (saving the page) |
| Name | up to 40 characters, "Just the product's name. No taglines or emoji." (G4) | `Nacho Combo` (11) | 🔒 |
| Tagline | up to 60 characters (G4) | pick one of 3 in [LISTING.md](LISTING.md) | 🔒 |
| Description | up to 500 characters (G4). Our drafts stay at 260 or less to be safe (the boss brief set 260). | pick one of 2 in LISTING.md | 🔒 |
| Launch tags (topics) | "required, up to 3" (G4). Names must exist on TOP. | see LISTING.md (Mac, Developer Tools, Open Source, Menu Bar Apps, Productivity verified to exist 2026-11-21) | 🔒 |
| Logo | "Recommended size: 240x240px. JPG, PNG, or GIF, up to 2MB." Animated logos only play on hover (G4). | app icon (`docs/images/app-icon.png`, resized) | 🔒 (upload) |
| Gallery images | "at least 1 required"; 3 or more recommended; "Recommended size: 1270x760px" (G4). ⚠ Unverified: maximum count, allowed formats and per-file size for gallery images (not stated in G4). | 5 to 8 images from ASSETS.md | 🔒 (upload) |
| Video | "optional but recommended"; added "by link" (G4). ⚠ Unverified: length, format, supported hosts, file-size limit. | `TBD after boss-approved upload` | 🔒 (upload / external publishing of the video) |
| Demo | optional clickable walkthrough "without signing up" (G4) | not planned (a desktop app has no web demo) | none |
| Pricing | Free, Paid or Free options (G4) | **Free** | 🔒 |
| Promo code | optional (G4) | none | none |
| Open source | optional company info: "whether it's open source (you'll need to link the repository)" (G4) | yes, repository link above | 🔒 |
| X handle and other company info | optional (G4) | ⚠ Unverified: no official X handle is documented in this repository; leave empty unless the boss gives one | 🔒 |
| Platform (macOS etc.) | ⚠ Unverified: no "platform" field was described in the guides read. If the form shows one, choose macOS. | macOS | 🔒 |
| Your role | "I made this" or "I'm hunting it" (G4) | "I made this" for a maker; hunter is not required (G8: "you can, and should, hunt your own product") | 🔒 |

## 3. Makers

| Step | Detail | Approval |
|---|---|---|
| Add makers | Click **Add makers**; "add everyone who built the product. You can add as many as you want." (G4) | 🔒 Boss approval required (names to credit) |
| Maker first comment | Written ahead of launch, "posted and pinned at the top of the discussion when you launch"; up to 5,000 characters; "Ask for feedback, never for upvotes." (G4). Draft: LISTING.md. | 🔒 |
| Shoutouts | Optional note of 20 to 2,000 characters for people who helped (G4). Not drafted. | 🔒 |

## 4. Launch date and time

- Every launch "goes live at **12:01 AM Pacific Time** on its scheduled date and runs for that full day, until midnight
  Pacific" (G3, G8). G4 words it as "starting at midnight Pacific Time"; the two differ by a minute, so plan for 00:01 PT.
- Schedule "from tomorrow up to 30 days ahead" (G3). Dates can be changed later (G3, G4).
- **"Create draft" versus "Schedule launch":** "If your launch isn't 100% finished, click Create draft, not Schedule
  launch. Scheduled launches are reviewed before they go live, and incomplete ones can be removed." (G4)
- Time zone conversion (PT is UTC-8 in winter, UTC-7 in summer): the 00:01 PT slot is 17:01 in Korea (KST, UTC+9) when PT is
  UTC-8 (Nov to early Mar), 16:01 KST in summer. ⚠ Unverified (estimate): the best weekday or day to launch; the
  guides read do not give one, so the boss chooses.
- 🔒 **Boss approval required:** choose the date; schedule the launch (this is the step that makes the launch go public
  automatically). Until then only "Create draft".

## 5. Pre-launch checklist (before the date)

G4 "Before you schedule" checklist, with our status (all start as open):

- [ ] Product works in production, signup included (the download needs no signup; a Nacho account is only for Nacho Pet chat)
- [ ] Name and tagline are clear on their own
- [ ] Gallery shows the product in use (needs the screenshots and video from the other NACHO-975 sub-issues)
- [ ] Co-makers are added and have accounts
- [ ] Maker comment is written
- [ ] Promo code works, if you have one (none)
- [ ] Posts for communities are written but **not sent** (LISTING.md). G5: "Prepare your email, social posts, and any in-app banner before the day, so you're not writing them at 1 AM."
- [ ] Website or README carries a Product Hunt badge, if wanted (G5: "Add a Product Hunt badge or embed to your homepage or a banner"). That needs a repository change and is out of scope here. 🔒 if done.

## 6. Launch day

No hour-by-hour timetable exists in the official guide (G6). The times below are our plan, marked
`⚠ Unverified (estimate)` where they are not official. PT = Pacific Time; the launch starts 00:01 PT.

| When (PT) | Task | Approval |
|---|---|---|
| Day before | Final read of the page and maker comment; confirm the Release page and download work; confirm who is online overnight | none |
| 00:01 | Launch goes live (official, G3). Confirm the page shows correctly. | 🔒 (already approved by scheduling) |
| 00:05 to 00:30 ⚠ | Check the maker comment is pinned (G4). Reply to first comments. | 🔒 Boss approval required (posting comments) |
| All day | "Answer every comment" you can, "as close to real time as possible"; "Split the day with your team... so someone is always online, including overnight" (G6). Goal: "real conversation and useful feedback, not a vote count" (G6). | 🔒 (each reply is an external post; see section 8 for pre-approved reply drafts if the boss wants them) |
| Morning US time ⚠ | Send community posts (drafts in LISTING.md). Share the link "everywhere your audience already is" but only where you are already active (G5). Never ask for upvotes. | 🔒 Boss approval required (SNS and community sending) |
| Evening ⚠ | Check the launch-day dashboard (position, points, comments; G6). Note questions for the FAQ. | none |
| 23:59 | Launch day ends (G3) | none |

Do not (G5, CG): ask for upvotes or run anything that "requires or rewards" them; pay for upvotes or comments; mass DM,
use scraped email lists; use fake or extra accounts; self-promote in other people's comments (CG).

## 7. After launch

| Step | Detail (G6) | Approval |
|---|---|---|
| Keep the conversation going | Answer late comments. | 🔒 |
| Follow up | "Reach back out to the users, prospects, and partners who engaged with you." | 🔒 |
| Measure against goals | Compare with the goals set in G3. | none |
| Turn feedback into improvements | Open issues in the repository for requests. | 🔒 (new issues are public) |
| Badge | If an award such as Product of the Day is given, "we'll email you a badge you can add to your website" (G6). Adding it to the README is a repository change. | 🔒 |
| Editing the page after launch | ⚠ Unverified: no article read says what can be edited after launch (G4 says name, tagline and description "can be changed any time before you launch"). Ask Product Hunt support before relying on it. | 🔒 |

## 8. Reply drafts for common comments (not posted)

Only the boss-approved person posts these, in their own words. Keep them honest, short and in line with
[SOURCES.md](SOURCES.md).

- Why is the app in Korean? "Right now the app screens are in Korean and an English UI is not done yet. The English text on this page comes from the product itself. English localization is not planned for this release." ⚠ The last sentence needs the boss to confirm; replace with a real plan if one exists.
- Is it safe, why unsigned? "Nacho Combo is ad-hoc signed and not notarized, so macOS blocks the first launch. Right-click the app, choose Open, then Open. The source is public so you can build it yourself."
- Windows? "This listing is for the macOS app. A separate project, NachoCombo for Windows, is in its own public repository: https://github.com/mafianacho/nachocombo-windows" (see LISTING.md FAQ for what was checked).

## 9. Approval summary (who must say yes)

Collected in [README.md](README.md#boss-approval-points). Summary: account creation or connection, who the makers are,
saving the product page, every upload (logo, images, video), choosing and scheduling the date, posting comments,
sending anything to X, Reddit or other communities, and anything that publishes outside this repository.
