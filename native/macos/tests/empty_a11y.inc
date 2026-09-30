// Empty accessibility tree for the native pump test. The live text client
// below is intentionally separate from the last rendered a11y snapshot.
uint32_t zenit_a11y_focused(uint32_t window_id) { return UINT32_MAX; }
int zenit_a11y_value(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_text_selection(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end, uint32_t *caret) { return 0; }
int zenit_a11y_text_range_at_point(uint32_t window_id, uint32_t handle, float x, float y, uint32_t *start_utf8, uint32_t *end_utf8) { return 0; }
int zenit_a11y_root_count(uint32_t window_id) { return 0; }
uint32_t zenit_a11y_root_at(uint32_t window_id, int idx) { return UINT32_MAX; }
int zenit_a11y_exists(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_children_count(uint32_t window_id, uint32_t parent_raw) { return 0; }
uint32_t zenit_a11y_children_at(uint32_t window_id, uint32_t parent_raw, int idx) { return 0; }
int zenit_a11y_role(uint32_t window_id, uint32_t handle) { return 0; }
uint32_t zenit_a11y_state(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_label(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_description(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_numeric_value(uint32_t window_id, uint32_t handle, float *now, float *min, float *max) { return 0; }
int zenit_a11y_frame(uint32_t window_id, uint32_t handle, float *x, float *y, float *width, float *height) { return 0; }
uint8_t zenit_a11y_actions(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_perform_action(uint32_t window_id, uint32_t handle, uint8_t action) { return 0; }
uint8_t zenit_a11y_text_capabilities(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_set_text_selection(uint32_t window_id, uint32_t handle, uint32_t start_utf8, uint32_t end_utf8) { return 0; }
int zenit_a11y_set_focus(uint32_t window_id, uint32_t handle, int focused) { return 0; }
int zenit_a11y_set_text_value(uint32_t window_id, uint32_t handle, const char *bytes, int len) { return 0; }
int zenit_a11y_text_visible_range(uint32_t window_id, uint32_t handle, uint32_t *start, uint32_t *end) { return 0; }
int zenit_a11y_text_frame(uint32_t window_id, uint32_t handle, uint32_t start_utf8, uint32_t end_utf8, float *x, float *y, float *width, float *height) { return 0; }
int zenit_a11y_set_numeric_value(uint32_t window_id, uint32_t handle, float value) { return 0; }
uint8_t zenit_a11y_numeric_capabilities(uint32_t window_id, uint32_t handle) { return 0; }
uint32_t zenit_a11y_parent(uint32_t window_id, uint32_t handle) { return UINT32_MAX; }
uint32_t zenit_a11y_active_descendant(uint32_t window_id, uint32_t handle) { return UINT32_MAX; }
uint32_t zenit_a11y_hit_test(uint32_t window_id, float x, float y) { return UINT32_MAX; }
uint8_t zenit_a11y_orientation(uint32_t window_id, uint32_t handle) { return 0; }
uint8_t zenit_a11y_sort_direction(uint32_t window_id, uint32_t handle) { return 0; }
uint16_t zenit_a11y_level(uint32_t window_id, uint32_t handle) { return 0; }
int zenit_a11y_row_index_range(uint32_t window_id, uint32_t handle, uint32_t *index, uint32_t *span) { return 0; }
int zenit_a11y_column_index_range(uint32_t window_id, uint32_t handle, uint32_t *index, uint32_t *span) { return 0; }
int zenit_a11y_placeholder(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
int zenit_a11y_identifier(uint32_t window_id, uint32_t handle, char *buf, int buf_len) { return 0; }
