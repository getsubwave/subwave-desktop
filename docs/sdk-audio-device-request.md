# Request: audio output-device selection in the platform seam

Written 2026-08-01 against `@native-sdk/cli` 0.7.1. Intended to be filed
upstream more or less as-is (see [vercel-labs/native][repo]).

## What's missing

There is no way for an app to ask which audio output devices exist, or to send
its playback to one of them. The whole audio surface in
`src/platform/types.zig` is:

```zig
audio_load_fn:       fn (context, path) anyerror!void
audio_load_url_fn:   fn (context, url, cache_path, expected_bytes) anyerror!AudioLoadResolution
audio_play_fn:       fn (context) anyerror!void
audio_pause_fn:      fn (context) anyerror!void
audio_stop_fn:       fn (context) anyerror!void
audio_seek_fn:       fn (context, position_ms) anyerror!void
audio_set_volume_fn: fn (context, volume) anyerror!void
```

`PlayAudioOptions` carries `key`, `path`, `url`, `cache_path`,
`expected_bytes`, `on_event` — nothing device-shaped. `AudioEvent` reports
`loaded` / `position` / `completed` / `failed` / `spectrum`, so an app cannot
even observe which device it landed on, let alone choose.

This is unchanged between 0.6.0 and 0.7.1: the `*_fn` service list and the
`PlatformFeature` enum are byte-identical across the two releases.

## Why an app wants it

Any app that plays audio for a long time, rather than in short bursts, ends up
wanting to pin its output: a radio player on the desk speakers while the
system default is a headset, a DJ tool with a cue bus, a meeting tool keeping
alerts on the internal speaker. The OS-level fallbacks are uneven:

| platform | per-app routing today |
| --- | --- |
| Linux | `pavucontrol` / PipeWire patchbay — works, but lives outside the app |
| Windows | Settings → System → Sound → Volume mixer — works, outside the app |
| macOS | **nothing** without a third-party virtual audio driver |

So on the platform with the strictest audio stack there is no answer at all,
and on the other two the answer is "leave the app and go configure the OS."

## Proposed shape

Additive, and matching the existing single-player model — one selection for
the app's one player.

```zig
/// Enumerate the host's audio output devices. `buffer` receives the ids and
/// names; the returned slice borrows from it.
audio_output_devices_fn: ?*const fn (context: ?*anyopaque, buffer: []u8) anyerror![]const AudioOutputDevice = null,

/// Route the single player at `device_id`. An empty id means "follow the
/// system default", which is today's only behavior. An id that has since
/// disappeared reports `.failed` and falls back to the default rather than
/// going silent.
audio_set_output_device_fn: ?*const fn (context: ?*anyopaque, device_id: []const u8) anyerror!void = null,

pub const AudioOutputDevice = struct {
    /// Stable across replug where the platform can manage it; opaque to apps.
    id: []const u8,
    /// Human-readable, for a picker row.
    name: []const u8,
    /// Whether this is the current system default.
    is_default: bool,
};
```

Plus a `PlatformFeature.audio_output_device` so `runtime.supports()` answers
honestly and a picker can hide itself on hosts that don't implement it — the
same shape `audio_streaming` and `audio_spectrum` already use.

An accompanying `AudioEvent` kind (`.output_device_changed`) would let an app
follow the device disappearing underneath it, though the fallback-to-default
behavior above is the important half.

## Per-platform implementation notes

**Linux (GStreamer, `gtk_host.c`).** `GstDeviceMonitor` with an
`Audio/Sink` filter enumerates devices and pushes add/remove messages on its
bus. `gst_device_create_element()` turns a chosen device into a ready sink
element, which becomes `playbin`'s `audio-sink`. The existing `spectrum`
analyzer is installed as playbin's `audio-filter`, so it is unaffected by the
sink swap. Changing sink on a live pipeline needs a state cycle down to
`GST_STATE_READY`; for a stream that means a reconnect, which is acceptable
and matches what a format switch already costs.

**macOS (AVPlayer, `appkit_host.m`).** `AVPlayer` already exposes
`audioOutputDeviceUniqueID` on macOS — assigning a CoreAudio device UID routes
that player, no pipeline rebuild. Enumeration is
`AudioObjectGetPropertyData` with `kAudioHardwarePropertyDevices`, filtering
for devices with output streams, reading
`kAudioDevicePropertyDeviceUID` for the id and
`kAudioObjectPropertyName` for the label. This is the platform with no OS-level
per-app routing, so it is also where the API is worth the most.

**Windows (Media Foundation, `webview2_host.cpp`).** `IMMDeviceEnumerator`
(`EnumAudioEndpoints` with `eRender`) enumerates; each `IMMDevice` gives an id
string and a friendly name via its property store. `IMFMediaEngineEx::SetAudioEndpointRole`
covers the coarse case, and the `IMFMediaEngineEx` audio endpoint id setter
covers a specific device. The host already links the WASAPI surface for the
process-loopback spectrum capture, so the COM plumbing is present.

## Interim

Nothing in-app. The SUB/WAVE desktop player documents the OS-level route in its
README and ships no picker, because faking one — restarting playback and hoping
the OS honors a per-app default — would be a worse experience than the honest
absence.

[repo]: https://github.com/vercel-labs/native
