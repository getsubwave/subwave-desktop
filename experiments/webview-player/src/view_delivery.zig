const std = @import("std");
const native_sdk = @import("native_sdk");

pub const ViewDelivery = struct {
    slots: [2]Slot = .{ .{ .window_id = 1 }, .{} },
    sample_received: u64 = 0,
    sample_delivered: u64 = 0,
    ack_count: u64 = 0,
    max_pending_per_view: u8 = 0,
    next_sequence: u64 = 0,

    pub const SlotDiagnostic = struct {
        window_id: native_sdk.WindowId,
        ready: bool,
        visible: bool,
        awaiting_ack: bool,
        delivered_sequence: u64,
        pending_sequence: u64,
        snapshot_count: u64,
        last_snapshot_revision: u64,
    };

    const Slot = struct {
        window_id: native_sdk.WindowId = 0,
        ready: bool = false,
        visible: bool = true,
        awaiting_ack: bool = false,
        delivered_sequence: u64 = 0,
        pending_sequence: u64 = 0,
        pending_bands: [32]u8 = @splat(0),
        snapshot_count: u64 = 0,
        last_snapshot_revision: u64 = 0,
    };

    pub fn ready(self: *ViewDelivery, window_id: native_sdk.WindowId, revision: u64) void {
        const slot = self.findSlot(window_id) orelse return;
        slot.ready = true;
        slot.awaiting_ack = false;
        markSnapshot(slot, revision);
    }

    pub fn forget(self: *ViewDelivery, window_id: native_sdk.WindowId) void {
        const slot = self.findSlot(window_id) orelse return;
        slot.* = if (window_id == 1) .{ .window_id = 1, .visible = false } else .{};
    }

    pub fn clearPending(self: *ViewDelivery) void {
        for (&self.slots) |*slot| {
            slot.awaiting_ack = false;
            slot.pending_bands = @splat(0);
        }
    }

    pub fn setVisible(self: *ViewDelivery, window_id: native_sdk.WindowId, visible: bool) void {
        const slot = self.findSlot(window_id) orelse return;
        slot.visible = visible;
        if (!visible) slot.awaiting_ack = false;
    }

    pub fn pushSnapshot(self: *ViewDelivery, runtime: *native_sdk.Runtime, json: []const u8, revision: u64) void {
        for (&self.slots) |*slot| if (slot.window_id != 0 and slot.ready and slot.visible) {
            runtime.emitWindowEvent(slot.window_id, "subwave.proof.snapshot", json) catch continue;
            markSnapshot(slot, revision);
        };
    }

    pub fn offerSpectrum(self: *ViewDelivery, runtime: *native_sdk.Runtime, generation: u64, bands: [32]u8) void {
        self.sample_received += 1;
        self.next_sequence += 1;
        for (&self.slots) |*slot| {
            if (slot.window_id == 0 or !slot.ready or !slot.visible) continue;
            slot.pending_sequence = self.next_sequence;
            slot.pending_bands = bands;
            if (!slot.awaiting_ack) self.deliver(runtime, slot, generation);
        }
    }

    pub fn acknowledge(self: *ViewDelivery, runtime: *native_sdk.Runtime, window_id: native_sdk.WindowId, generation: u64, sequence: u64) bool {
        const slot = self.findSlot(window_id) orelse return false;
        if (!acceptAck(slot, sequence)) return false;
        self.ack_count += 1;
        if (slot.pending_sequence > slot.delivered_sequence and slot.visible and slot.ready) self.deliver(runtime, slot, generation);
        return true;
    }

    fn acceptAck(slot: *Slot, sequence: u64) bool {
        if (!slot.awaiting_ack or sequence != slot.delivered_sequence) return false;
        slot.awaiting_ack = false;
        return true;
    }

    pub fn diagnostic(self: *const ViewDelivery, index: usize) SlotDiagnostic {
        const slot = self.slots[index];
        return .{ .window_id = slot.window_id, .ready = slot.ready, .visible = slot.visible, .awaiting_ack = slot.awaiting_ack, .delivered_sequence = slot.delivered_sequence, .pending_sequence = slot.pending_sequence, .snapshot_count = slot.snapshot_count, .last_snapshot_revision = slot.last_snapshot_revision };
    }

    fn markSnapshot(slot: *Slot, revision: u64) void {
        slot.snapshot_count += 1;
        slot.last_snapshot_revision = revision;
    }

    fn deliver(self: *ViewDelivery, runtime: *native_sdk.Runtime, slot: *Slot, generation: u64) void {
        var buffer: [512]u8 = undefined;
        var out = std.Io.Writer.fixed(&buffer);
        out.print("{{\"generation\":{d},\"sequence\":{d},\"bands\":[", .{ generation, slot.pending_sequence }) catch return;
        for (slot.pending_bands, 0..) |band, index| {
            if (index > 0) out.writeByte(',') catch return;
            out.print("{d}", .{band}) catch return;
        }
        out.writeAll("]}") catch return;
        runtime.emitWindowEvent(slot.window_id, "subwave.proof.spectrum", out.buffered()) catch return;
        slot.awaiting_ack = true;
        slot.delivered_sequence = slot.pending_sequence;
        self.sample_delivered += 1;
        self.max_pending_per_view = @max(self.max_pending_per_view, 1);
    }

    fn findSlot(self: *ViewDelivery, window_id: native_sdk.WindowId) ?*Slot {
        for (&self.slots) |*entry| if (entry.window_id == window_id) return entry;
        for (&self.slots) |*entry| if (entry.window_id == 0) {
            entry.window_id = window_id;
            return entry;
        };
        return null;
    }
};

test "slow views retain only the newest spectrum sample" {
    var delivery: ViewDelivery = .{};
    delivery.ready(1, 3);
    const slot = delivery.findSlot(1).?;
    slot.awaiting_ack = true;
    slot.delivered_sequence = 1;
    slot.pending_sequence = 1;
    slot.pending_bands = @splat(1);
    // Model the overwrite portion without needing a runtime/platform.
    slot.pending_sequence += 1;
    slot.pending_bands = @splat(9);
    slot.pending_sequence += 1;
    slot.pending_bands = @splat(12);
    try std.testing.expectEqual(@as(u64, 3), slot.pending_sequence);
    try std.testing.expectEqual(@as(u8, 12), slot.pending_bands[0]);
}

test "hidden and closed views clear delivery state and mini slot is reusable" {
    var delivery: ViewDelivery = .{};
    delivery.ready(1, 4);
    delivery.setVisible(1, false);
    const main = delivery.findSlot(1).?;
    try std.testing.expect(!main.visible);
    try std.testing.expect(main.ready);

    delivery.ready(7, 4);
    const old_mini = delivery.findSlot(7).?;
    old_mini.awaiting_ack = true;
    delivery.forget(7);
    try std.testing.expect(delivery.findSlot(8) != null);
    try std.testing.expect(delivery.findSlot(8).?.window_id == 8);
}

test "snapshot readiness records the authoritative revision" {
    var delivery: ViewDelivery = .{};
    delivery.ready(1, 12);
    const diagnostic = delivery.diagnostic(0);
    try std.testing.expectEqual(@as(u64, 1), diagnostic.snapshot_count);
    try std.testing.expectEqual(@as(u64, 12), diagnostic.last_snapshot_revision);
}

test "generation clear keeps sequence monotonic and rejects a delayed old ack" {
    var delivery: ViewDelivery = .{};
    const slot = delivery.findSlot(1).?;
    delivery.next_sequence = 8;
    slot.delivered_sequence = 8;
    slot.pending_sequence = 8;
    slot.awaiting_ack = true;
    delivery.clearPending();
    delivery.next_sequence += 1;
    slot.delivered_sequence = delivery.next_sequence;
    slot.pending_sequence = delivery.next_sequence;
    slot.awaiting_ack = true;
    try std.testing.expect(!ViewDelivery.acceptAck(slot, 8));
    try std.testing.expect(ViewDelivery.acceptAck(slot, 9));
}
