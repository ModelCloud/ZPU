//! Boundary reserved for Vulkan loader negotiation, handles, and entry points.
//! No Vulkan entry points are exported in the CPU 2D milestone.
pub const Status = enum { unavailable };
pub fn status() Status {
    return .unavailable;
}
