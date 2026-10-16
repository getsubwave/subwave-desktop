#include <assert.h>
#include <stdint.h>
#include <string.h>

/* Compile the real private SDK implementation into this test translation unit
 * so its static GLib/GStreamer callback entry points are exercised directly. */
#include "gtk_host.c"

static void assert_audio_equal(const native_sdk_gtk_audio_t *actual, const native_sdk_gtk_audio_t *expected) {
    assert(memcmp(actual, expected, sizeof(*actual)) == 0);
}

static void count_event(void *context, const native_sdk_gtk_event_t *event) {
    (void)event;
    (*(unsigned int *)context)++;
}

int main(void) {
    native_sdk_gtk_host_t host = {0};
    unsigned int emitted = 0;
    host.callback = count_event;
    host.callback_context = &emitted;
    native_sdk_audio_callback_context_t current = {
        .host = &host,
        .bus = (void *)(uintptr_t)0x42,
        .load_id = 42,
    };
    native_sdk_audio_callback_context_t stale = {
        .host = &host,
        .bus = (void *)(uintptr_t)0x41,
        .load_id = 41,
    };

    host.audio.callback_context = &current;
    host.audio.bus = current.bus;
    host.audio.load_id = current.load_id;
    host.audio.active = 1;
    host.audio.ready = 0;
    host.audio.playing = 1;
    host.audio.buffering = 1;
    host.audio.duration_ms = 1234;
    host.audio.position_timer = 99;

    native_sdk_gtk_audio_t before = host.audio;
    native_sdk_audio_on_async_done(stale.bus, NULL, &stale);
    assert_audio_equal(&host.audio, &before);
    native_sdk_audio_on_error(stale.bus, NULL, &stale);
    assert_audio_equal(&host.audio, &before);
    native_sdk_audio_on_eos(stale.bus, NULL, &stale);
    assert_audio_equal(&host.audio, &before);
    native_sdk_audio_on_buffering(stale.bus, NULL, &stale);
    assert_audio_equal(&host.audio, &before);
    native_sdk_audio_on_state_changed(stale.bus, NULL, &stale);
    assert_audio_equal(&host.audio, &before);
    native_sdk_audio_on_element(stale.bus, NULL, &stale);
    assert_audio_equal(&host.audio, &before);
    assert(native_sdk_audio_position_tick(&stale) == G_SOURCE_REMOVE);
    assert_audio_equal(&host.audio, &before);

    /* A matching timer whose player has become inactive must retire itself and
     * clear only the registered timer id. */
    host.audio.active = 0;
    host.audio.position_timer = 99;
    assert(native_sdk_audio_position_tick(&current) == G_SOURCE_REMOVE);
    assert(host.audio.position_timer == 0);
    assert(host.audio.load_id == 42);
    assert(host.audio.callback_context == &current);
    assert(host.audio.bus == current.bus);

    assert(emitted == 0);
    return 0;
}
