# TestFlight + Apple Distribution — Step by Step

Two phases:
- **Phase 1 — TestFlight** (now): get the app on Adele, Pieter, Hennie & Matt's phones.
- **Phase 2 — Non-public App Store** (later): a private/unlisted link for the wider group.

---

## Phase 0 — Prerequisites (5 min to confirm)
1. **Paid Apple Developer Program** ($99/yr) on your Apple ID. You already have distribution certs +
   Team ID `RF4R5X25Y2`, so you're almost certainly enrolled — confirm at
   https://developer.apple.com/account (it should say "Membership: active").
2. **A neutral display name & bundle id.** Bundle id is `com.nvdberg.hackingbolt`.
   ⚠️ **Important — read the "Naming" note at the bottom before you submit anything to Apple.**
   For TestFlight *internal* testing you can ship as-is; for external TestFlight and the App Store,
   the name "Hacking-Bolt" and the Lightning Bolt branding are a review risk. Easiest to rename now.

---

## Phase 1 — TestFlight

### Step 1 — Create the app record in App Store Connect
1. Go to https://appstoreconnect.apple.com → **Apps → ➕ → New App**.
2. Platform: **iOS**. Name: your chosen app name (see Naming note). Primary language: English.
3. Bundle ID: pick `com.nvdberg.hackingbolt` from the list (if it's not there, register it first at
   developer.apple.com → Certificates, IDs & Profiles → Identifiers).
4. SKU: anything unique (e.g. `hackingbolt01`). Create.

### Step 2 — Archive & upload the build (from Xcode)
1. Open `hacking-bolt-ios/HackingBolt.xcodeproj`.
2. Set the run destination to **Any iOS Device (arm64)** (top bar — not a simulator).
3. Bump the build number if needed (target → General → Build).
4. **Product → Archive.** When it finishes, the Organizer window opens.
5. **Distribute App → App Store Connect → Upload.** Accept the defaults, let it sign automatically
   with your distribution cert, and upload.
6. Wait ~10–30 min for it to finish "Processing" in App Store Connect → your app → **TestFlight** tab.
7. **Export compliance:** when prompted, the app only uses standard HTTPS → answer that it does **not**
   use non-exempt encryption. (You can make this permanent by adding
   `ITSAppUsesNonExemptEncryption = NO` to Info.plist.)

### Step 3 — Add your testers
You have two options. For 4 trusted people I recommend **Option A (Internal)** — it's instant and
skips Apple's review.

**Option A — Internal testers (fastest, no review, up to 100)**
1. App Store Connect → **Users and Access → ➕** → invite each person's Apple ID email
   (Adele, Pieter, Hennie, Matt). Give them the **"Customer Support"** role (lowest access that still
   allows TestFlight) — or "Developer" if you want. They accept the email invite.
2. App Store Connect → your app → **TestFlight → Internal Testing → ➕ group** (e.g. "Crew").
   Add those users to the group and enable the build.
3. They get a TestFlight invite immediately — **no Apple review, live in minutes.**
   (Trade-off: internal testers are members of your App Store Connect team, so they can technically
   sign into your account. Fine for family/close colleagues; if that bothers you, use Option B.)

**Option B — External testers (email-only, needs one beta review ~24h)**
1. TestFlight → **External Testing → ➕ group** → add testers by email (no account access needed).
2. Fill in the "Test Information" (what to test, a contact email) and **submit the build for Beta App
   Review.** First build of a version gets a light review (~a day); later builds usually auto-approve.
3. On approval, Apple emails each tester a TestFlight invite.
   (This is the path that scales to the whole 28-person group later — up to 10,000 testers.)

### Reusable tester list across ALL your apps (internal testers)
This is the "shareable list for other apps": **internal testers are members of your App Store Connect
account, not just one app** — so once someone's on it, you can drop them into any current or future
app's Internal Testing group instantly, no re-inviting.

**Example — adding your brother Herman:**
1. App Store Connect → **Users and Access → ➕** → Herman's **Apple ID email** + name → give him a
   **role** (Developer is fine, or "Customer Support" for the least access) → ensure **"Access to
   TestFlight"** is on → Invite. He accepts the email.
2. He's now on your account — for *any* app, you just add him to that app's Internal group.
3. For this app: **TestFlight → Internal Testing → your group → ➕ → Herman** → enable the build. He can
   install immediately (no review).
- No UDID needed (that's the old Ad Hoc way). Up to 100 internal testers, all cross-app, all instant.
- Note: an internal tester gets some access to your App Store Connect via their role — fine for family;
  pick a low role to limit it. (For zero account access, use External testers, but those are per-app +
  need a review and aren't reusable across apps.)
- Herman can install & browse the app, but not being on your Lightning Bolt scheduler he can't log in, so
  the shift screens stay empty for him — expected; still handy for testing the UI and your future apps.

### Step 4 — What your testers do (put this in the message below)
1. Install **TestFlight** from the App Store (free Apple app).
2. Open the invite email / link → **Accept** → **Install**.
3. Open the app → **log into Lightning Bolt** on the real LB screen inside the app (you never see their
   password; the app just drives their own session).
4. Check the **Pool** tab shows open shifts (incl. Rapid Response), and the accept links open Lightning
   Bolt's own accept screen.

---

## Copy-paste message to send your testers

> **Subject: Try my Lightning Bolt companion app (TestFlight)**
>
> Hi — I've built a little iPhone app that makes our shift pool way easier to see and act on: it shows
> every open shift chronologically (all units, near and far), flags the ones that clash with your own
> roster, and gives you a one-tap link straight to Lightning Bolt's accept screen. There's also a
> "Who's On" whole-group view and a "Crew" view.
>
> It's a personal tool that just reads *your own* Lightning Bolt account — I never see your password,
> and it never accepts anything for you; you always tap accept yourself on Lightning Bolt's own screen.
>
> To try it:
> 1. Install **TestFlight** from the App Store (free).
> 2. Tap this invite: **[TestFlight link Apple gives you]**
> 3. Install, open the app, and log into Lightning Bolt on the screen it shows you.
>
> It's an early beta, so tell me anything that looks wrong or could be better. Thanks for testing! 🙏
>
> — Nicolaas

*(Adele first, then Pieter, Hennie, Matt. For internal testers the "invite link" is automatic once you
add them; for external testers Apple sends it after the beta review.)*

---

## Phase 2 — Non-public ("unlisted") App Store distribution

When you're ready to give the whole group a stable install without a public listing, there are two
real routes:

1. **TestFlight external, long-term** (simplest, recommended first): up to **10,000** testers by email,
   no public App Store presence at all. Downside: builds expire after **90 days**, so you re-upload a
   fresh build periodically. For a 28-person group this is honestly the easiest home and avoids full
   App Store review politics.

2. **Unlisted App Store distribution**: the app is fully approved but **not searchable** — you share a
   direct link. To get it:
   - Submit the app for normal **App Store Review** (App Store Connect → your app → prepare a version →
     Submit for Review).
   - After approval, request an unlisted link:
     https://developer.apple.com/contact/request/unlisted-app-distribution
   - Apple issues a permanent, non-searchable App Store URL you share with the group.

### ⚠️ Naming / trademark / review caveats — read before submitting to Apple
Be aware these can trip App Store review (they do **not** affect internal TestFlight):
- **The name "Hacking-Bolt"** and using **"Lightning Bolt" / "Bolt"** — Lightning Bolt is PerfectServe's
  trademarked product. An app named after it, or trading on its branding, can be rejected. **Rename to
  something neutral** (e.g. "Shift Pool", "Call Companion", "Roster Buddy") and describe it as a
  personal companion, not an official client.
- **App Store Guideline 5.2.2** (unofficial third-party service clients): apps that surface another
  company's service without authorization can be rejected. Framing matters — it reads/organizes *your
  own authorized data* and links back to the vendor's own screens, which is the honest, defensible
  description. Have that ready.
- Because of the above, **App Store review may reject it** even unlisted. If it does, **TestFlight
  external is your practical distribution channel** for the group — no public review gate.

**My recommendation:** start Phase 2 as **long-term TestFlight external** (rename + one beta review),
and only pursue the unlisted App Store link if you specifically want a permanent, non-expiring install.
Talk to me when you're back and I'll help with the rename, the App Store Connect metadata, and the
review description wording.

---

## Quick gotchas checklist
- [ ] Confirm paid Developer Program is active.
- [ ] Add `ITSAppUsesNonExemptEncryption = NO` to Info.plist (skips the export-compliance prompt each build).
- [ ] Give the app a real display name + the 1024px icon is already set.
- [ ] Archive uses **Any iOS Device**, Release config, automatic distribution signing.
- [ ] For external testers, builds expire after 90 days — set a reminder to re-upload.
- [ ] Decide on the rename before anything external/App-Store-facing.
