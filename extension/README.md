# Working-Bolt browser extension

A way to start Working-Bolt on a computer without the bookmark. You sign in to Lightning Bolt as usual and Working-Bolt opens over it by itself.

- **Opens by itself** when you reach the Lightning Bolt dashboard while signed in. If you close it, it stays closed in that tab until you open it again.
- **⚡ Working-Bolt button** (bottom right of every Lightning Bolt page) and the **toolbar icon** open it again. On any other site, the toolbar icon opens Lightning Bolt.
- **Stays hidden** on the sign-in page. The extension never sees, fills or stores a password. It only runs on `lblite.lightning-bolt.com`.
- **Same app as the bookmark.** It loads a bundled copy of `web/wb.js` into the Lightning Bolt tab, so it reads with that tab's own sign-in. Same rules: read-only unless you click and confirm.

## Why an extension at all

Lightning Bolt's server only answers its own site (`lblite.lightning-bolt.com`). A page hosted anywhere else, such as working-bolt.github.io, can't sign in or read rosters. Working-Bolt therefore has to run inside a Lightning Bolt tab, and only a bookmark or an extension can put it there.

## Build

`tools/make-extension.sh` copies the current `web/wb.js` in and writes `dist-extension/WorkingBolt-extension-<version>.zip`. The copied `extension/wb.js` and `dist-extension/` are gitignored.

Store copies don't update themselves. After a `wb.js` change you want extension users to get: bump `version` in `manifest.json`, rebuild, and upload the new zip.

## Try it (Chrome or Edge)

1. Run `tools/make-extension.sh`.
2. Open `chrome://extensions` (or `edge://extensions`), turn on **Developer mode**, click **Load unpacked**, and choose this `extension/` folder.
3. Go to Lightning Bolt and sign in.

## Publishing (the owner's call)

| Store | Cost | Notes |
|---|---|---|
| Chrome Web Store | one-time US$5 developer fee | Review usually takes a few days. Can be listed as **Unlisted**, so only people with the link find it. |
| Microsoft Edge Add-ons | free | Same zip. |
| Firefox Add-ons | free | Needs a small manifest tweak (`background.scripts`). |
| Safari | — | Needs a Mac app wrapper through Xcode. Not done. |

The store listing needs a privacy note: no data collected. Everything stays in the browser, apart from the same Working-Bolt backend the app uses (pickups, notifications).

Hospital-managed computers may block extensions. The bookmark keeps working as the fallback.
