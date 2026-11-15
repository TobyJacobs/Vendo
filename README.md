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
- **Event checklist**: guests get a to-do list for each booking, matched to the type of event.
- **Venue tools**: the host dashboard has tabs for an overview, the calendar, rooms and prices (several rooms per venue, each with its own price and calendar, plus prices by day of the week), listing quality and insights (a completeness score, views, searches and a comparison with similar venues), and payouts (with a downloadable CSV statement).
- **Trust**: Verified venue, Replies within an hour and Top host badges; Vendo Booking Protection on every booking; guest photos on reviews.
- **Installable app**: `manifest.webmanifest`, app icons and a service worker (`sw.js`) let people add Vendo to their phone's home screen and keep using it on a weak signal.
- **Search engines**: structured data for the organisation, website and FAQs. Venue markup is written but switched off (`PUBLISH_VENUE_SCHEMA`) until the listings are real venues.
- **Accessibility**: checked with axe in light mode, dark mode and every event theme, with no remaining issues. Includes a skip link, keyboard focus kept inside pop-ups, and page titles for each view.
- **Event moods**: the colours change with the occasion. For example, weddings switch the app to black and white.

All venues, hosts, bookings and figures are fictional examples.

## Run it locally

Open `index.html` in a browser.

## Deploy

The site is plain HTML, so any static host works. On Netlify, connect this repository with no build command and set the publish directory to the repository root.
