//! Provider-neutral icons used by Zenit's own components.
//!
//! Application code may use the full Lucide catalog through `ui.icons`. Core
//! components use only these semantic names so switching providers never
//! requires rewriting framework source files.

const icons = @import("zenit_icons");

pub const provider_name = "lucide";
pub const Asset = icons.Asset;

pub const activity = icons.activity;
pub const alert = icons.circle_alert;
pub const audio = icons.headphones;
pub const check = icons.check;
pub const close = icons.x;
pub const search = icons.search;
pub const heart = icons.heart;
pub const star = icons.star;
pub const home = icons.house;
pub const settings = icons.settings;
pub const notification = icons.bell;
pub const calendar = icons.calendar;
pub const user = icons.user;
pub const mail = icons.mail;
pub const trash = icons.trash_2;
pub const download = icons.download;
pub const upload = icons.upload;
pub const edit = icons.pencil;
pub const copy = icons.copy;
pub const lock = icons.lock;
pub const chevron_down = icons.chevron_down;
pub const chevron_up = icons.chevron_up;
pub const chevron_left = icons.chevron_left;
pub const chevron_right = icons.chevron_right;
pub const minus = icons.minus;
pub const plus = icons.plus;
pub const more_horizontal = icons.ellipsis;

pub const cursor_default = icons.mouse_pointer_2;
pub const cursor_click = icons.mouse_pointer_click;
pub const pointer = icons.hand_pointing;
pub const move = icons.move;
pub const not_allowed = icons.ban;
pub const grab = icons.hand;
pub const resize_horizontal = icons.chevrons_left_right;
pub const resize_vertical = icons.chevrons_up_down;
pub const resize_diagonal = icons.expand;
pub const wait = icons.hourglass;
pub const progress = icons.loader_circle;
pub const help = icons.circle_help;

// Status glyphs and stack controls used by the Notifier.
pub const warning = icons.triangle_alert;
pub const info = icons.info;
pub const chevrons_up = icons.chevrons_up;
pub const pause = icons.pause;

// Color-scheme toggle (DevTools header).
pub const sun = icons.sun;
pub const moon = icons.moon;
