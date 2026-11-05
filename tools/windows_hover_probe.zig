//! Process entry for the native Win32 hover reference (tools/windows_hover_probe.c).
extern fn zenit_windows_hover_probe_main() c_int;

pub fn main() u8 {
    return @intCast(zenit_windows_hover_probe_main());
}
