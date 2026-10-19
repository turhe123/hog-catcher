# HogCatcher — specification

**Tagline:** Warns you when an app quietly burns CPU in the background, so you can quit it and save battery.

**Category:** System Monitoring

**Inspired by (paid):** MenuBarMonitor ($15 one-time)

**Frameworks:** SwiftUI, AppKit, Darwin, UserNotifications, ServiceManagement

**Donation URL (Support button):** https://ko-fi.com/leodavidai

## Spec

What the paid app does. MenuBarMonitor is a menu bar system monitor available on Setapp and listed as a fifteen dollar one-time purchase, with a background hog detector that helps catch resource-hungry apps. Demand evidence is that it appears in battery monitor comparisons next to iStat Menus, and the question of what is draining my battery or spinning my fans is among the most common Mac support threads. Existing ideas in our list cover general meters, so ours focuses on one sharp job, catching sustained background offenders and offering a one-click fix.

Our clean-room feature set. A sampler measures CPU usage of every user process once every five seconds. A process becomes a hog when it uses more than a configurable percent of one core, default sixty, continuously for more than a configurable number of minutes, default three, and is not the frontmost app. When detected, the app posts a notification with the app name, how long and how hard, and buttons Quit App, Ignore for Today and Never Warn. The popover shows the top five current CPU consumers with live bars, plus a list of recent hog incidents with timestamps. An allow list holds apps such as video editors or compilers that are expected to be busy. Around four hundred lines.

UI spec. MenuBarExtra in window style. The icon is a small flame that is gray when calm and orange when a hog is active. The popover has a Now section with the top five rows, each with a Quit and Force Quit button in a context menu, an Incidents section with the last twenty incidents, and footer buttons for Settings and Quit. Settings has CPU threshold slider from twenty to two hundred percent, duration stepper from one to thirty minutes, a switch to only watch while on battery, a table for the allow list with add and remove buttons, notification switch and launch at login. Empty state says Everything looks calm. Keyboard shortcut Command comma opens Settings.

Technical approach. List processes and read cumulative CPU time with proc_pid_rusage, converting user plus system time deltas between samples into a percentage of one core. Group helper processes by their bundle through NSRunningApplication and parent pid so a browser and its renderers count as one app. Track consecutive over-threshold seconds per app in memory. Determine the frontmost app through NSWorkspace and exempt it. Detect battery power with IOPSCopyPowerSourcesInfo for the on-battery-only switch. Quit uses NSRunningApplication terminate, with Force Quit offered only after a confirmation. Notifications use UserNotifications with a registered category. Settings live in UserDefaults and incidents in a small JSON file in Application Support. Launch at login via SMAppService. No special permissions are needed for the same-user processes the app can read.

Edge cases. System processes owned by root cannot be quit, so list them as informational without buttons. Ignore processes younger than ten seconds to avoid launch spikes. Never offer to quit Finder, the window server or the app itself. After sleep, discard the first sample to avoid a false spike. If a process disappears between sample and quit, show a brief message. Cap incident history at one hundred entries and snooze duplicates for thirty minutes per app.
