# Vendo

Vendo helps pubs, village halls, bars, clubs and leisure centres rent out their rooms for weddings, parties, wakes, christenings and other events.

This repository holds the clickable demo. It is a single static page (`index.html`) with no build step.

## What's in the demo

- **Book a venue**: search and filter eleven example venues, from village halls to nightclubs, by event type, region and guest numbers. Each listing has an availability calendar and a quote builder.
- **For venues**: a host dashboard with room-hire income, enquiries to accept or decline, upcoming bookings and an earnings estimator.
- **Venue calendar**: venues see Vendo bookings, bookings they took by phone or in person, and dates they've blocked on one month view. Adding a booking or blocking a date closes it on their public listing straight away, so they can't be double-booked. Entries are saved in the browser.
- **Map**: switch to a map of venues, pick a town or use your location, and see what is nearby within a chosen radius.
- **Guest accounts and ratings**: a guest's account page shows their rating from venue owners, what venues said about them, and their bookings. Venues see each guest's rating on enquiries and rate guests after events.
- **List your venue**: a sign-up page for venue owners with how it works, an earnings estimator, FAQs and a short form.
- **Search by date** and **full prices including fees** on every card, plus guest reviews and a shareable link for each venue.
- **Saved venues, filters and messaging**: heart venues to save them, filter by price, instant book, step-free access, licensed bar or outdoor space, and message venues (contact details are held back until a booking is confirmed).
- **How it works, FAQs and footer pages**: About, Contact, Terms, Privacy and Cookies. Terms and Privacy are drafts and need a solicitor's review before launch.
- **Link previews**: `og-image.jpg` shows when the site is shared.
- **Help guests decide**: a budget planner that totals room, food and drinks at each venue; nearest free dates and similar venues when a date is taken; a waiting list for booked dates; recently viewed venues; and "Good to know" details (finish time, music, parking, transport, own cake, rainy-day plan) on every listing.
- **Booking page**: a full checkout with event details, contact details, deposit or full payment, the venue's cancellation policy and house rules, then a confirmation page with what happens next and a calendar file. Payment is shown as a hand-off to Stripe; the demo asks for no card details.
- **Event checklist**: guests get a to-do list for each booking, matched to the type of event.
- **Venue tools**: the host dashboard has tabs for an overview, the calendar, rooms and prices (several rooms per venue, each with its own price and calendar, plus prices by day of the week), listing quality and insights (a completeness score, views, searches and a comparison with similar venues), and payouts (with a downloadable CSV statement).
- **Trust**: Verified venue, Replies within an hour and Top host badges; Vendo Booking Protection on every booking; guest photos on reviews.
- **Installable app**: `manifest.webmanifest`, app icons and a service worker (`sw.js`) let people add Vendo to their phone's home screen and keep using it on a weak signal.
- **Search engines**: structured data for the organisation, website and FAQs. Venue markup is written but switched off (`PUBLISH_VENUE_SCHEMA`) until the listings are real venues.
- **Accessibility**: checked with axe in light mode, dark mode and every event theme, with no remaining issues. Includes a skip link, keyboard focus kept inside pop-ups, and page titles for each view.
- **Event moods**: the colours change with the occasion. For example, weddings switch the app to black and white.

All venues, hosts, bookings and figures are fictional examples.

## iPhone app

The iPhone app wraps this same website with [Capacitor](https://capacitorjs.com), so every website change reaches the app too. The Xcode project is in `ios/`.

Needs a Mac with Xcode and Node.js. To run it:

1. `npm install` (first time only).
2. `npm run ios`. This copies the website into the app, then opens Xcode.
3. In Xcode, pick an iPhone simulator (or your own iPhone) and press ⌘R.

After changing the website, run `npm run ios:sync` to copy the changes into the app.

- **App icon and launch screen:** made from `assets/icon-only.png`, `assets/splash.png` and `assets/splash-dark.png`. After changing them, run `npx @capacitor/assets generate --ios`.
- **Native features:** the share sheet, haptics, the status bar and the launch screen. They are used from `index.html` only when it runs inside the app, so the website is unchanged.
- **Bundle ID:** `uk.footprintgroup.vendo` (in `capacitor.config.json`). Change it before the first App Store upload if you want a different one.
- **Shared links:** set `SITE_URL` in `index.html` to the website's address, so links shared from inside the app point to the website.
- **App Store:** you need an Apple Developer account (£79 a year). Then, in Xcode, set your team under Signing & Capabilities, choose Product › Archive, and upload to App Store Connect.

## Versions

The site uses version numbers: 0.x while Vendo is a demo, and 1.0.0 at the public launch. The current version shows in the footer, and the What's new page (`#changelog`) lists every release. [CHANGELOG.md](CHANGELOG.md) has the same list.

To release a new version:

1. Add an entry at the top of `RELEASES` in `index.html`.
2. Run `./release.sh 0.11.0` with the new number. Use the last number for fixes and the middle number for new features.
3. Push with `git push origin main --follow-tags`.

Every release has a git tag (`v0.9.0`, `v0.10.0` and so on), so any earlier version can be looked at or restored.

## Run it locally

Open `index.html` in a browser for a quick look (pages use `#` addresses there).

To see the site as Netlify serves it, with real page addresses:

```bash
npm run site
npm run preview
```

Then open http://localhost:8000. The preview serves `/about` from `about.html`, like Netlify does.

## Deploy and search engines

Netlify runs `node scripts/build-site.mjs` (set in `netlify.toml`) and publishes `dist/`. The build:

- gives every page its own address and HTML file, such as `/about`, `/list-your-venue` and `/venues/the-plough-and-harrow`, each with its own title, description, canonical link, share card and readable content
- writes `sitemap.xml` and `robots.txt`, and a `404.html` for unknown addresses
- reads the site address from `SITE_URL` in `index.html` (currently https://vendohire.netlify.app)

Venue pages are kept out of search results while the listings are fictional. When real venues go live, set `INDEX_VENUES` to `true` in `index.html` (and `PUBLISH_VENUE_SCHEMA` for rich results), then add the site to Google Search Console and submit the sitemap.

Old `#` links (`#about`, `#venue-plough`) still work: the site moves them to the new address. The map library now loads only when someone opens the map, so pages load faster.
