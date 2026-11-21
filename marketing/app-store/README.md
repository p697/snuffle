# App Store screenshots

Six posters per language, drawn at 1320 × 2868 and uploaded at 1206 × 2622 ("iPhone with Dynamic Island, medium display",
the one size App Store Connect requires; it scales those for every other iPhone):

1. Every app and platform in one place: the four sources wired into the home screen.
2. Today's revenue across apps, down to each order.
3. One tap refreshes everything: home right after a refresh, with the cat.
4. Reviews from both stores, answered in one place.
5. Home Screen widget (Pro).
6. Privacy: direct, on device, open source.

The phones show real simulator screenshots of demo mode's made-up products.

## Files

- `copy.js`: the text of every poster in every language, and the font each language uses.
- `index.html`: the layout. Open it in Chrome for a contact sheet of all languages; `?lang=de&shot=3` shows one poster.
- `capture.sh`: takes the simulator screenshots into `screens/<lang>/` (git-ignored).
- `render.sh`: renders the posters into `out/<lang>/1.png` … `6.png`, plus the 1206 × 2622 copies App Store Connect
  takes in `out/<lang>/upload/` (git-ignored).

## Making them

1. Build the app for the simulator (debug) and install it on an iPhone 17 Pro Max simulator.
2. Once, by hand: add the medium "今日" widget at the top of that simulator's Home Screen.
3. `SIM=<udid> ./capture.sh` (all languages, about 90 seconds each; pass language codes to do a few).
4. `./render.sh`, then look over `index.html` before uploading.

Headlines in Chinese, Japanese, Korean, Thai, Hindi and Arabic use Noto Sans from Google Fonts; every other language
uses SF Pro's compressed width, so render on a Mac with SF Pro installed (Apple's developer fonts).

The debug launch arguments `capture.sh` relies on (`-storeShots`, `-tab`, `-refreshAfterLaunch`) are listed in
`ios/README.md`.
