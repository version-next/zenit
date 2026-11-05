/* wl_seat/pointer up to version 8: coordinates and scroll values are logical units.
 * Keep button transitions queued; a full queue is a transport error, never a
 * silent loss of the release that would leave a widget permanently pressed. */
static void enqueue_pointer_button(ZenitWaylandWindow *w, uint32_t button, int pressed, int cancelled) {
    if (getenv("ZENIT_WAYLAND_IME_TRACE")) fprintf(stderr,
        "IME pointer button x=%.2f y=%.2f button=%u pressed=%d cancelled=%d\n",
        w->input.x, w->input.y, button, pressed, cancelled);
    if (w->ordered_input) {
        enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 1, .x = w->input.x, .y = w->input.y,
            .button = button, .pressed = (uint32_t)pressed, .cancelled = (uint32_t)cancelled, .modifiers = keyboard_modifiers(w) });
        if (pressed) w->input.buttons |= 1u << button; else w->input.buttons &= ~(1u << button);
        return;
    }
    if (w->button_count == 32) {
        fprintf(stderr, "Wayland button queue overflow\n"); w->closed = 1; return;
    }
    w->buttons[(w->button_head + w->button_count++) % 32] = (ZenitWaylandButtonEvent){
        w->input.x, w->input.y, button, (uint32_t)pressed, (uint32_t)cancelled };
    if (pressed) w->input.buttons |= 1u << button;
    else w->input.buttons &= ~(1u << button);
}
static void cancel_pointer_buttons(ZenitWaylandWindow *w) {
    for (uint32_t button = 0; button < 3; ++button)
        if (w->input.buttons & (1u << button)) enqueue_pointer_button(w, button, 0, 1);
}
/* Shadow-margin resize border (shadow.inc). These handle events on the shadow
 * strips natively; the application never sees them. */
static int shadow_pointer_enter(ZenitWaylandWindow *w, struct wl_surface *surface, uint32_t serial, float x, float y);
static int shadow_pointer_leave(ZenitWaylandWindow *w, struct wl_surface *surface);
static int shadow_pointer_motion(ZenitWaylandWindow *w, float x, float y);
static int shadow_pointer_button(ZenitWaylandWindow *w, uint32_t serial, uint32_t button, uint32_t state);
static void pointer_enter(void *data, struct wl_pointer *pointer, uint32_t serial,
                          struct wl_surface *surface, wl_fixed_t x, wl_fixed_t y) {
    (void)pointer; (void)serial; ZenitWaylandWindow *w = data;
    if (shadow_pointer_enter(w, surface, serial, (float)x / 256, (float)y / 256)) return;
    if (surface != w->surface) return;
    w->pointer_enter_serial = serial; w->pointer_focused = 1;
    /* Hover acceptance evidence (scripts/run_linux_hover_acceptance.py): pointer focus is
     * independent of keyboard focus (activation). */
    if (getenv("ZENIT_WAYLAND_POINTER_TRACE")) fprintf(stderr,
        "POINTER native enter x=%.1f y=%.1f keyboard_focused=%d\n", (float)x / 256, (float)y / 256, w->keyboard_focused);
    if (!apply_cursor(w)) fprintf(stderr, "Wayland cursor unavailable\n");
    if (!w->pointer_focused) return;
    w->input.x = (float)x / 256; w->input.y = (float)y / 256;
    if (w->ordered_input) enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 4, .x = w->input.x, .y = w->input.y, .modifiers = keyboard_modifiers(w) });
}
static void emit_scroll(ZenitWaylandWindow *, float, float, uint32_t);
static void reset_axis_frame(ZenitWaylandWindow *);
static void pointer_leave(void *data, struct wl_pointer *pointer, uint32_t serial, struct wl_surface *surface) {
    (void)pointer; (void)serial; ZenitWaylandWindow *w = data;
    if (shadow_pointer_leave(w, surface)) return;
    if (surface != w->surface) return;
    if (getenv("ZENIT_WAYLAND_POINTER_TRACE")) fprintf(stderr,
        "POINTER native leave keyboard_focused=%d\n", w->keyboard_focused);
    if (w->gesture_active) emit_scroll(w, 0, 0, 5);
    w->gesture_active = 0; w->gesture_axes = 0; reset_axis_frame(w);
    w->pointer_focused = 0; w->cursor_deadline = 0; cancel_pointer_buttons(w);
    /* Kind 9: the pointer left the surface. The last motion position is stale from here on;
     * queued after any button cancellation so the sequence ends before hover is dropped. */
    if (w->ordered_input) enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 9, .x = w->input.x, .y = w->input.y, .modifiers = keyboard_modifiers(w) });
}
static void pointer_motion(void *data, struct wl_pointer *pointer, uint32_t time, wl_fixed_t x, wl_fixed_t y) {
    (void)pointer; (void)time; ZenitWaylandWindow *w = data;
    if (shadow_pointer_motion(w, (float)x / 256, (float)y / 256)) return;
    if (!w->pointer_focused) return;
    w->input.x = (float)x / 256; w->input.y = (float)y / 256;
    if (w->ordered_input) enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 4, .x = w->input.x, .y = w->input.y, .modifiers = keyboard_modifiers(w) });
}
static void pointer_button(void *data, struct wl_pointer *pointer, uint32_t serial,
                          uint32_t time, uint32_t button, uint32_t state) {
    (void)pointer; (void)serial; (void)time;
    if (shadow_pointer_button(data, serial, button, state)) return;
    if (!((ZenitWaylandWindow *)data)->pointer_focused) return;
    if (state == WL_POINTER_BUTTON_STATE_PRESSED) clipboard_input_serial(data, serial);
    uint32_t slot;
    switch (button) { case 272: slot = 0; break; case 273: slot = 1; break; case 274: slot = 2; break; default: return; }
    ZenitWaylandWindow *w = data;
    if(state==WL_POINTER_BUTTON_STATE_PRESSED&&w->chrome_mode&&!w->decoration_manager_seen&&w->chrome_hit&&w->chrome_hit(w->chrome_context,w->input.x,w->input.y)==2) {
        if(slot==1&&w->toplevel&&w->seat) {
            union wl_argument args[]={{.o=(struct wl_object *)w->seat},{.u=serial},{.i=(int32_t)w->input.x},{.i=(int32_t)w->input.y}};
            request(w,w->toplevel,XDG_TOPLEVEL_SHOW_WINDOW_MENU,NULL,1,0,args);
            return;
        }
        const char *action=NULL;
        if(slot==2) action=w->chrome_middle_click;
        if(slot==0) {
            float dx=w->input.x-w->chrome_last_press_x,dy=w->input.y-w->chrome_last_press_y;
            if(w->chrome_last_press_valid&&(uint32_t)(time-w->chrome_last_press_time)<=450&&dx*dx+dy*dy<=64) {
                action=w->chrome_double_click;w->chrome_last_press_valid=0;
            } else {w->chrome_last_press_valid=1;w->chrome_last_press_time=time;w->chrome_last_press_x=w->input.x;w->chrome_last_press_y=w->input.y;}
        }
        if(action) {
            if(!strcmp(action,"toggle-maximize"))zenit_wayland_set_maximized(w,!w->maximized);
            else if(!strcmp(action,"minimize"))zenit_wayland_set_minimized(w);
            else if(!strcmp(action,"menu")&&w->toplevel&&w->seat){
                union wl_argument args[]={{.o=(struct wl_object *)w->seat},{.u=serial},{.i=(int32_t)w->input.x},{.i=(int32_t)w->input.y}};
                request(w,w->toplevel,XDG_TOPLEVEL_SHOW_WINDOW_MENU,NULL,1,0,args);
            }
            return;
        }
    } else if(state==WL_POINTER_BUTTON_STATE_PRESSED&&slot==0) w->chrome_last_press_valid=0;
    /* Resolve synchronously on the actual press, with its own seat and serial.
     * Never store/reuse clipboard or pointer-enter serials for window moves. */
    if (slot == 0 && state == WL_POINTER_BUTTON_STATE_PRESSED && w->chrome_mode && !w->decoration_manager_seen && w->chrome_hit) {
        int region = w->chrome_hit(w->chrome_context, w->input.x, w->input.y);
        if (!(w->decor_window_state & (LIBDECOR_WINDOW_STATE_MAXIMIZED | LIBDECOR_WINDOW_STATE_FULLSCREEN))) {
            float x=w->input.x, y=w->input.y;
            int left=x<5, right=x>w->width-5, top=y<5, bottom=y>w->height-5;
            if (top) region=left?6:right?9:3;
            else if (bottom) region=left?7:right?10:4;
            else if (left) region=5;
            else if (right) region=8;
        }
        if (region == 2 && !(w->decor_window_state & LIBDECOR_WINDOW_STATE_FULLSCREEN) && w->decor_api.move && (!w->decor_api.has_capability || w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_MOVE))) {
            w->decor_api.move(w->decor_frame, w->seat, serial);
            return;
        }
        if (region >= 3 && region <= 10 && !(w->decor_window_state & (LIBDECOR_WINDOW_STATE_MAXIMIZED | LIBDECOR_WINDOW_STATE_FULLSCREEN)) && w->decor_api.resize && (!w->decor_api.has_capability || w->decor_api.has_capability(w->decor_frame,LIBDECOR_ACTION_RESIZE))) {
            w->decor_api.resize(w->decor_frame, w->seat, serial, (enum libdecor_resize_edge)(region-2));
            return;
        }
    }
    enqueue_pointer_button(data, slot, state == WL_POINTER_BUTTON_STATE_PRESSED, 0);
}
/* Wayland axis deltas describe scroll offsets; Zenit deltas describe content
 * motion (as on macOS/Windows). The compositor already applies natural-scroll
 * preferences: invert once at this boundary, never again for device settings. */
static void emit_scroll(ZenitWaylandWindow *w, float dx, float dy, uint32_t phase) {
    if (getenv("ZENIT_WAYLAND_SCROLL_TRACE")) fprintf(stderr,
        "SCROLL native dx=%.4f dy=%.4f phase=%u\n", dx, dy, phase);
    if (getenv("ZENIT_WAYLAND_POINTER_TRACE")) fprintf(stderr,
        "POINTER native axis dy=%.4f keyboard_focused=%d\n", dy, w->keyboard_focused);
    if (w->ordered_input) {
        enqueue_input(w, (ZenitWaylandInputEvent){ .kind = 5, .x = w->input.x, .y = w->input.y,
            .dx = dx, .dy = dy, .scroll_phase = phase, .modifiers = keyboard_modifiers(w) });
    } else { w->scroll_x += dx; w->scroll_y += dy; }
}
static void reset_axis_frame(ZenitWaylandWindow *w) {
    memset(w->axis_delta, 0, sizeof(w->axis_delta));
    memset(w->axis_steps, 0, sizeof(w->axis_steps));
    memset(w->axis_v120, 0, sizeof(w->axis_v120));
    w->axis_present = w->axis_steps_present = w->axis_v120_present = w->axis_stopped = 0;
    w->axis_source_known = 0;
}
static void pointer_axis(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis, wl_fixed_t value) {
    (void)pointer; (void)time; ZenitWaylandWindow *w = data;
    if (!w->pointer_focused || axis > WL_POINTER_AXIS_HORIZONTAL_SCROLL) return;
    const float delta = (float)value / 256;
    if (w->seat_version < 5) {
        emit_scroll(w, axis == WL_POINTER_AXIS_HORIZONTAL_SCROLL ? -delta : 0,
            axis == WL_POINTER_AXIS_VERTICAL_SCROLL ? -delta : 0, 0);
        return;
    }
    w->axis_delta[axis] += delta; w->axis_present |= 1u << axis;
}
static void pointer_axis_source(void *data, struct wl_pointer *pointer, uint32_t source) {
    (void)pointer; ZenitWaylandWindow *w = data;
    if (!w->pointer_focused) return;
    w->axis_source = source; w->axis_source_known = 1;
}
static void pointer_axis_stop(void *data, struct wl_pointer *pointer, uint32_t time, uint32_t axis) {
    (void)pointer; (void)time; ZenitWaylandWindow *w = data;
    if (w->pointer_focused && axis <= WL_POINTER_AXIS_HORIZONTAL_SCROLL) w->axis_stopped |= 1u << axis;
}
static void pointer_axis_discrete(void *data, struct wl_pointer *pointer, uint32_t axis, int32_t discrete) {
    (void)pointer; ZenitWaylandWindow *w = data;
    if (!w->pointer_focused || axis > WL_POINTER_AXIS_HORIZONTAL_SCROLL) return;
    w->axis_steps[axis] += discrete; w->axis_steps_present |= 1u << axis;
}
static void pointer_axis_value120(void *data, struct wl_pointer *pointer, uint32_t axis, int32_t value120) {
    (void)pointer; ZenitWaylandWindow *w = data;
    if (!w->pointer_focused || axis > WL_POINTER_AXIS_HORIZONTAL_SCROLL) return;
    w->axis_v120[axis] += (float)value120; w->axis_v120_present |= 1u << axis;
}
static void pointer_frame(void *data, struct wl_pointer *pointer) {
    (void)pointer; ZenitWaylandWindow *w = data;
    if (!w->pointer_focused) { reset_axis_frame(w); return; }
    const int finger = w->axis_source_known && w->axis_source == WL_POINTER_AXIS_SOURCE_FINGER;
    const int wheel = w->axis_source_known && (w->axis_source == WL_POINTER_AXIS_SOURCE_WHEEL ||
        w->axis_source == WL_POINTER_AXIS_SOURCE_WHEEL_TILT);
    float deltas[2] = {0, 0};
    for (uint32_t axis = 0; axis < 2; ++axis) {
        const uint32_t bit = 1u << axis;
        /* One detent is 40 logical px, matching the Windows backend. Keep
         * fractional high-resolution steps; never add value120 and axis twice.
         * Fingers/continuous devices retain exact compositor pixel deltas. */
        if (wheel && (w->axis_v120_present & bit)) deltas[axis] = -w->axis_v120[axis] / 120.0f * 40.0f;
        else if (wheel && (w->axis_steps_present & bit)) deltas[axis] = -w->axis_steps[axis] * 40.0f;
        else deltas[axis] = -w->axis_delta[axis] * (wheel ? 4.0f : 1.0f);
    }
    if (deltas[0] != 0 || deltas[1] != 0) {
        if (!finger && w->gesture_active) { emit_scroll(w, 0, 0, 5); w->gesture_active = 0; w->gesture_axes = 0; }
        const uint32_t phase = finger ? (w->gesture_active ? 3 : 2) : 0;
        if (finger) { w->gesture_active = 1; w->gesture_axes |= w->axis_present; }
        emit_scroll(w, deltas[1], deltas[0], phase);
    }
    w->gesture_axes &= ~w->axis_stopped;
    if (w->gesture_active && w->axis_stopped && w->gesture_axes == 0) {
        emit_scroll(w, 0, 0, 4); w->gesture_active = 0;
    }
    reset_axis_frame(w);
}
static const struct wl_pointer_listener pointer_listener = {
    .enter = pointer_enter, .leave = pointer_leave, .motion = pointer_motion,
    .button = pointer_button, .axis = pointer_axis, .frame = pointer_frame,
    .axis_source = pointer_axis_source, .axis_stop = pointer_axis_stop,
    .axis_discrete = pointer_axis_discrete, .axis_value120 = pointer_axis_value120,
};
static void seat_capabilities(void *data, struct wl_seat *seat, uint32_t capabilities) {
    ZenitWaylandWindow *w = data;
    if ((capabilities & WL_SEAT_CAPABILITY_POINTER) && !w->pointer) {
        union wl_argument args[] = { { .o = NULL } };
        w->pointer = (struct wl_pointer *)request(w, seat, WL_SEAT_GET_POINTER, &wl_pointer_interface, w->seat_version, 0, args);
        if (!w->pointer || listen(w, w->pointer, &pointer_listener, w) != 0) w->closed = 1;
        init_cursor_device(w);
    } else if (!(capabilities & WL_SEAT_CAPABILITY_POINTER) && w->pointer) {
        cancel_pointer_buttons(w); destroy_cursor_device(w);
        w->api.destroy_proxy((struct wl_proxy *)w->pointer); w->pointer = NULL;
    }
    if ((capabilities & WL_SEAT_CAPABILITY_KEYBOARD) && !w->keyboard) {
        union wl_argument args[] = {{.o = NULL}};
        w->keyboard = (struct wl_keyboard *)request(w, seat, WL_SEAT_GET_KEYBOARD, &wl_keyboard_interface, w->seat_version, 0, args);
        if (!w->keyboard || listen(w, w->keyboard, &keyboard_listener, w) != 0) w->closed = 1;
    } else if (!(capabilities & WL_SEAT_CAPABILITY_KEYBOARD) && w->keyboard) {
        cancel_keyboard(w); w->keyboard_focused = 0;
        w->api.destroy_proxy((struct wl_proxy *)w->keyboard); w->keyboard = NULL;
    }
}
static void seat_name(void *data, struct wl_seat *seat, const char *name) {
    (void)data; (void)seat; (void)name;
}
static const struct wl_seat_listener seat_listener = { .capabilities = seat_capabilities, .name = seat_name };
int zenit_wayland_input_state(ZenitWaylandWindow *w, ZenitWaylandInputState *out) {
    if (!w || !out) return 0;
    *out = w->input; return 1;
}
int zenit_wayland_pop_button(ZenitWaylandWindow *w, ZenitWaylandButtonEvent *out) {
    if (!w || !out || !w->button_count) return 0;
    *out = w->buttons[w->button_head];
    w->button_head = (w->button_head + 1) % 32; --w->button_count; return 1;
}
int zenit_wayland_pop_scroll(ZenitWaylandWindow *w, ZenitWaylandScrollEvent *out) {
    if (!w || !out || (w->scroll_x == 0 && w->scroll_y == 0)) return 0;
    *out = (ZenitWaylandScrollEvent){ w->input.x, w->input.y, w->scroll_x, w->scroll_y };
    w->scroll_x = w->scroll_y = 0; return 1;
}
