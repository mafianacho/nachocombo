# Release PR checklist (`release/*`)

Every `release/*` PR copies this list into its description and ticks it. A missing item sends the PR back.

- [ ] Every feature in the notes has an image. Images are in `docs/release-notes/assets/vX.Y.Z/` and linked with the tag-pinned raw URL `https://raw.githubusercontent.com/mafianacho/nachocombo/vX.Y.Z/docs/release-notes/assets/vX.Y.Z/<file>` (no relative paths; `release.yml` attaches only the notes file).
- [ ] The notes follow the format (title → what you can do → image → 1–3 steps), and have the render-source line and the "Not yet tried on a real Mac" section.
- [ ] `Resources/WhatsNew/<version>.json` and its GIFs are updated for this version. Each GIF is 1.5 MB or less; captures hide personal data and use fake data only.
