// Real bridge queue reads, with no global input or system input-source changes.
#import "../window_bridge.m"
// Standalone empty accessibility fixture; no untracked helper dependency.
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
#include <assert.h>
uint64_t zenit_text_input_length(uint32_t w) { return 0; }
int zenit_text_input_copy(uint32_t w, uint64_t s, char *b, int n) { return 0; }
int zenit_text_input_selection(uint32_t w, uint32_t *s, uint32_t *e, uint32_t *c) { return 0; }
int zenit_text_input_frame(uint32_t w, uint32_t s, uint32_t e, float *x, float *y, float *a, float *b) { return 0; }
int zenit_text_input_range_at_point(uint32_t w, float x, float y, uint32_t *s, uint32_t *e) { return 0; }
uint64_t zenit_text_input_utf16_for_utf8(uint32_t w, uint64_t n) { return n; }
uint64_t zenit_text_input_utf8_for_utf16(uint32_t w, uint64_t n) { return n; }

void zenit_test_global_reset(void) { zenitPendingMenuCommands=[NSMutableArray array]; }
void zenit_test_global_enqueue(uint64_t command) {
 ZenitMenuCommandTarget *target=[ZenitMenuCommandTarget new];
 NSMenuItem *item=[NSMenuItem new]; item.representedObject=@(command);
 [target invokeZenitMenuCommand:item];
}
#ifndef ZENIT_GLOBAL_EVENTS_NO_MAIN
int main(void) {
 @autoreleasepool {
  [NSApplication sharedApplication];
  zenit_test_global_reset();
  for (uint64_t i=1;i<=300;i++) zenit_test_global_enqueue(i);
  assert(zenitPendingMenuCommands.count==300 && zenitHasPendingMenuCommands());
  NSTimeInterval before=[NSDate timeIntervalSinceReferenceDate];
  macos_pump_app_events_timeout(1000);
  assert([NSDate timeIntervalSinceReferenceDate]-before<0.8);
  uint64_t window,command;
  for (uint64_t i=1;i<=300;i++) {
   assert(macos_menu_poll_command(&window,&command)==1);
   assert(command==i && window==0);
  }
  assert(macos_menu_poll_command(&window,&command)==0);
  [zenitPendingMenuCommands addObject:@{@"windowId":@7,@"commandId":@1}];
  [zenitPendingMenuCommands addObject:@{@"windowId":@0,@"commandId":@2}];
  [zenitPendingMenuCommands addObject:@{@"windowId":@8,@"commandId":@3}];
  [zenitPendingMenuCommands addObject:@{@"windowId":@7,@"commandId":@4}];
  macos_menu_discard_window_commands(7);
  macos_menu_discard_window_commands(0);
  assert(macos_menu_poll_command(&window,&command)==1 && window==0 && command==2);
  assert(macos_menu_poll_command(&window,&command)==1 && window==8 && command==3);
  assert(!zenitHasPendingMenuCommands());
  // Remove queued wake events, then exercise a callback inside a blocking wait.
  while ([NSApp nextEventMatchingMask:NSEventMaskAny untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES]) {}
  for (int i=0;i<8;i++) macos_pump_app_events_timeout(0);
  __block BOOL fired=NO;
  dispatch_async(dispatch_get_main_queue(), ^{
   fired=YES; zenit_test_global_enqueue(999);
   NSEvent *marker=[NSEvent otherEventWithType:NSEventTypeApplicationDefined location:NSZeroPoint modifierFlags:0 timestamp:0 windowNumber:0 context:nil subtype:123 data1:0 data2:0];
   [NSApp postEvent:marker atStart:YES];
  });
  before=[NSDate timeIntervalSinceReferenceDate];
  macos_pump_app_events_timeout(1000);
  fprintf(stderr,"async fired=%d elapsed=%.3f count=%lu\n",fired,[NSDate timeIntervalSinceReferenceDate]-before,(unsigned long)zenitPendingMenuCommands.count);
  assert(fired && [NSDate timeIntervalSinceReferenceDate]-before<0.8);
  assert(macos_menu_poll_command(&window,&command)==1 && command==999);
  NSEvent *deferred=[NSApp nextEventMatchingMask:NSEventMaskApplicationDefined untilDate:[NSDate distantPast] inMode:NSDefaultRunLoopMode dequeue:YES];
  assert(deferred && deferred.subtype==123);
  fprintf(stderr,"PASS: 300 ordered commands, pending gate, async wake and scoped purge\n");
 }
 return 0;
}
#endif
