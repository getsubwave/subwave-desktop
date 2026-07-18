# Announcement voice

The user's announcement style for SUB/WAVE releases: a person typing in their
own Discord, not a launch press release. The rules that produced the approved
drafts below:

- First person, present tense, lowercase-casual where natural.
- Lead with the one or two facts that are genuinely surprising (binary size,
  keeps-playing-when-closed) — not a feature list.
- Concrete numbers over adjectives ("2.6 MB", never "lightweight").
- Honest asides beat polish: flag untested platforms as "tell me what
  happens, good or bad", admit what's missing ("linux: source only for now").
- One or two emoji total, where a person would actually drop one — never
  one per bullet.
- No section headers in bold, no "Get it"/"What's new" scaffolding in the
  short form; the long form may use plain short labels.
- No em-dash chains, no "it's not just X, it's Y", no "seamless/powerful".

## Approved long-form example (v0.1.0)

> ok so I built a desktop app for SUB/WAVE 📻
>
> It's fully native — Zig, no Electron, no browser pretending to be an app.
> The macOS download is 2.6 MB, which is smaller than most of the songs it
> plays. I keep checking that number because it doesn't feel real.
>
> It does the whole thing: tune into your station (or anyone's — the
> community directory is built in), see what the AI DJ is saying and playing,
> send requests from the little request slip, browse the week's schedule and
> the play history. It picks up whatever theme your station broadcasts and
> repaints itself live, which looks very cool when a station flips to its
> night theme while you're listening.
>
> My favorite part: close the window and it just keeps playing. It sits in
> the menu bar like a radio should. There's a sleep timer, a mini player, and
> the whole thing drives from the keyboard — space to tune, M to mute, 1-5
> for the dial, cmd+K for stations.
>
> The spectrum at the bottom is real FFT from the actual audio, not a fake
> animation.
>
> Downloads:
> mac: [link]
> windows: [link] — fair warning, this one compiled but I haven't tested it
> on a real Windows machine yet. if you run it, tell me what happens, good
> or bad
> linux: source only for now
>
> First launch asks you for a station URL — your own box or a friend's. You
> join whatever's on, that's the whole idea.
>
> Bugs → [repo link]

## Approved short-form example

> new: SUB/WAVE has a native desktop app 📻
>
> Zig, no Electron — the mac download is 2.6 MB, smaller than most of the
> songs it plays. Tune into any station, send the DJ requests, and close the
> window: it keeps playing from the menu bar like a radio should.
>
> mac: [link] · windows: [link] (untested on real hardware — reports
> welcome) · linux: source for now
>
> point it at your station and see what's on → [repo link]

For subsequent releases, the same voice but scoped to what changed: lead with
the most tangible new thing a listener would notice, keep the download links,
drop the intro-to-the-app material.
