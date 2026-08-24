//! The backend-independent part of swapchain lifetime.
//!
//! Vulkan reports the same two recovery conditions from two different
//! boundaries: image acquisition and presentation.  Keeping the transition
//! here gives the platform loop one small, testable rule: an out-of-date
//! image cannot be used, a suboptimal image may finish the current frame, and
//! both conditions schedule a rebuild before the next frame.

const std = @import("std");

pub const AcquireResult = enum {
    success,
    suboptimal,
    out_of_date,
};

pub const PresentResult = enum {
    success,
    suboptimal,
    out_of_date,
};

pub const AcquireDecision = enum {
    proceed,
    rebuild,
};

pub const PresentDecision = enum {
    ready,
    rebuild,
};

/// Apply the result of `vkAcquireNextImageKHR` to the caller-owned stale
/// marker.  `VK_SUBOPTIMAL_KHR` is usable for this frame, but must still
/// cause a rebuild before another frame is acquired.  `VK_ERROR_OUT_OF_DATE`
/// has no usable image and therefore asks the caller to return immediately.
pub fn acquired(stale: *bool, result: AcquireResult) AcquireDecision {
    switch (result) {
        .success => return .proceed,
        .suboptimal => {
            stale.* = true;
            return .proceed;
        },
        .out_of_date => {
            stale.* = true;
            return .rebuild;
        },
    }
}

/// Apply the result of `vkQueuePresentKHR`.  A suboptimal present completed
/// the frame, so it is reported separately from an out-of-date present even
/// though both require the next swapchain to be rebuilt.
pub fn presented(stale: *bool, result: PresentResult) PresentDecision {
    switch (result) {
        .success => return .ready,
        .suboptimal, .out_of_date => {
            stale.* = true;
            return .rebuild;
        },
    }
}

/// A zero-sized configure is a real minimized surface, not a request to
/// create a 1x1 swapchain.  The caller tears down its resources and waits for
/// a later non-zero configure before clearing the stale marker.
pub fn recreated(stale: *bool, width: u32, height: u32) bool {
    if (width == 0 or height == 0) {
        stale.* = true;
        return false;
    }
    stale.* = false;
    return true;
}

test "acquire out-of-date cannot proceed, while suboptimal finishes once" {
    var stale = false;
    try std.testing.expectEqual(.proceed, acquired(&stale, .success));
    try std.testing.expect(!stale);

    try std.testing.expectEqual(.proceed, acquired(&stale, .suboptimal));
    try std.testing.expect(stale);

    stale = false;
    try std.testing.expectEqual(.rebuild, acquired(&stale, .out_of_date));
    try std.testing.expect(stale);
}

test "present recovery and zero-size restore preserve rebuild ordering" {
    var stale = false;
    try std.testing.expectEqual(.rebuild, presented(&stale, .suboptimal));
    try std.testing.expect(stale);
    try std.testing.expect(!recreated(&stale, 0, 720));
    try std.testing.expect(stale);
    try std.testing.expect(!recreated(&stale, 1280, 0));
    try std.testing.expect(stale);
    try std.testing.expect(recreated(&stale, 1280, 720));
    try std.testing.expect(!stale);
    try std.testing.expectEqual(.ready, presented(&stale, .success));
}
