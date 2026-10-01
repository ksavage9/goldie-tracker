# Goldie Tracker

An iPad keeps Find My open on Goldie's AirTag. A shortcut takes a screenshot every 5 minutes.
The Goldie Tracker app turns each day's screenshots into a video with the time stamped on every
frame, and plays it back.

## Install (about 2 minutes)

1. On the iPad, install **Swift Playgrounds** from the App Store (it's free).
2. Get `GoldieTracker.zip` onto the iPad. The easiest way from a Windows PC is to go to
   **icloud.com → iCloud Drive** in a web browser and upload the zip. You can also email it
   to yourself or use OneDrive.
3. On the iPad, open **Files**, find the zip, and tap it to unzip. Then tap
   **GoldieTracker.swiftpm**. It opens in Swift Playgrounds.
4. Tap **▶ Run**.

The app opens to a **setup checklist** (about 5 minutes). It has buttons that jump to Shortcuts
and start the tracker. It shows a ✓ once screenshots are arriving, then switches to the day list.
You can reopen the checklist later with the **Setup** button.

To use the app later, open Swift Playgrounds → Goldie Tracker → ▶.

**If the app shows a black screen:** Swift Playgrounds stops the app while another app is in
front, and the shortcut brings Find My to the front every 5 minutes. When you come back, tap
**▶ Run** to start it again. Your folder, settings and animations are saved. If ▶ Run doesn't
bring it back, close Swift Playgrounds (swipe it up from the app switcher) and open it again;
that usually means iPadOS shut the app down, for example to free memory.

## What Apple requires you to do by hand

iPadOS doesn't let any app or script change Settings, create shortcuts, or add automations,
so the checklist walks you through these:

- Auto-Lock → Never
- Building the 11-action **Goldie Snap** shortcut
- Adding one daily **12:00 AM** automation
- Choosing the `Goldie` folder in the app

## Using the app

- **Days list:** tap any day to play its animation.
- **Jump to:** the date picker at the top of the list opens a calendar. Pick any day to go
  straight to it.
- **Build Now / Rebuild:** makes a day's animation right away from every screenshot available
  so far, including today's, then plays it. Once a day has an animation, the button says
  **Rebuild** and remakes it on demand.
- **Delete Animation:** on a day with an animation, tap **•••** → **Delete Animation**. If the
  day's screenshots are still saved, they stay, and the animation isn't rebuilt automatically;
  tap **Build Now** to bring it back. If they were already removed to save space, the animation
  can't be rebuilt, so the day disappears from the list. The app asks before deleting.
- **Time Range:** on any day, tap **Time Range** to make an animation from exactly the stretch
  you pick, with a **From** and **To** date and time. The range can cross days (for example,
  Tuesday 6 PM to Wednesday 8 AM). When it does, each frame shows the date as well as the time.
  This animation is only kept while you watch it, so it doesn't use up storage.
- **Under the video:** play/pause, the ◀︎ and ▶︎ frame buttons (one screenshot, 5 minutes, per
  tap), the scrubber, and the speed menu (0.25× to 4×; the app remembers your choice). Nothing is
  drawn over the video, and the time of each screenshot is in the bottom-right corner of the frame.
- **Heat Map:** on any day, tap **Heat Map** to see where Goldie spent her time. The glow runs
  from blue (passing through) to red (most time), and her busiest spot gets a pulsing marker.
  The first time, tap the center of her marker on the map once, so the app knows what to look
  for; it then finds her in every screenshot on its own. Each screenshot is lined up with the
  day's last one, so small moves of the map are fine; zoomed screenshots are skipped, and the heat
  map says how many. A sighting in a new place only counts if something changed there since the
  screenshot before, so icons and labels that look like her marker are ignored. Use **Pick
  Marker Again** if results look off.
- **Daily animations:** whenever the app is open, it builds an animation for each finished day
  that doesn't have one yet. It also rebuilds one that's out of date, for example if you tapped
  Build Now in the afternoon.
- **Status:** the top of the list shows when the last screenshot was taken. If none has
  arrived for 15 minutes, or none are saved, it turns red and shows a **Restart** button that
  starts the Goldie Snap shortcut.

## Good to know

- **While you use the app on this iPad, the shortcut brings Find My back to the front** at
  the next 5-minute mark. That's expected. Switch back to keep watching.
- **Animations can't be built in the background.** If the app goes to the background while an
  animation is building (for example, when Find My comes to the front), the build stops. It's
  retried automatically about 15 minutes later, and the previous animation is kept until a new
  one is finished.
- **"Goldie Snap wants to take a screenshot":** iPadOS asks this the first time the shortcut
  takes a screenshot. Tap **OK**, not Don't Allow. It should be remembered after that. While the
  question is on screen, no screenshots are taken, so the status turns red if nobody answers. If
  it keeps coming back, open Shortcuts → **•••** on Goldie Snap → details (ⓘ) → **Privacy**, tap
  **Reset Privacy**, run the shortcut once and tap **OK**. Editing the shortcut may also make it
  ask again.
- **iPadOS may sometimes stop a long-running shortcut.** Use the Restart button when that
  happens. The midnight automation starts it fresh every day anyway.
- **Storage:** screenshots take roughly 100–200 MB a day. The **Storage** section in the day
  list shows how much Goldie's files use and how much space the iPad has free. Goldie's files are
  kept under a limit you pick in **Setup** (the gear button): 2, 5, 10 or 20 GB, where 5 GB is
  about a month of screenshots. The app always leaves at least 2 GB free on the iPad.
  - When space runs out, the oldest days' screenshots are removed first, but only after that
    day's animation is finished. The animation stays, and so does the day in the list. Heat Map
    and Build Now are turned off for that day, because they need the screenshots.
  - The oldest animations are removed only as a last resort.
  - Today's screenshots, and any day still waiting for its animation, are never removed.
- **AirTag limits:** an AirTag doesn't have GPS. Its location updates only when a nearby
  iPhone or iPad passes it along. Updates can be 15–60+ minutes apart in quiet areas, so
  you'll see Goldie jump between spots rather than trace a path. If you need to know for sure
  whether she's crossing the street, a GPS cat collar (like Tractive) shows her actual route.
