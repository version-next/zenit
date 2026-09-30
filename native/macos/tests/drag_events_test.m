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

void *zenit_test_drag_window_create(void) {
 WindowWrapper *w=[WindowWrapper new];
 w.metalView=[[MetalView alloc] initWithFrame:NSZeroRect];
 return (__bridge_retained void *)w;
}
void zenit_test_drag_window_destroy(void *ptr) { CFBridgingRelease(ptr); }
void zenit_test_drag_enqueue(void *ptr, const uint8_t *bytes, size_t length, uint8_t kind) {
 WindowWrapper *w=(__bridge WindowWrapper *)ptr;
 NSString *paths=[[NSString alloc] initWithBytes:bytes length:length encoding:NSUTF8StringEncoding];
 assert(paths);
 [w.metalView.dragEventQueue addObject:@{@"x":@12,@"y":@34,@"kind":@(kind),@"paths":paths,@"payloadKind":@1,@"sourceToken":@123456789,@"operation":@2}];
}
#ifndef ZENIT_DRAG_EVENTS_NO_MAIN
int main(void) {
 @autoreleasepool {
  void *ptr=zenit_test_drag_window_create();
  WindowWrapper *w=(__bridge WindowWrapper *)ptr;
  NSMutableString *paths=[[@"/tmp/漢\n" stringByPaddingToLength:8000 withString:@"路徑" startingAtIndex:0] mutableCopy];
  NSData *expected=[paths dataUsingEncoding:NSUTF8StringEncoding];
  [w.metalView enqueueDragEventAtX:12 y:34 kind:3 paths:paths payloadKind:1];
  [paths setString:@"mutated"];
  char buf[4096]; memset(buf,0x55,sizeof(buf)); float x,y; uint8_t kind,pk,op,tr; uint64_t source;
  int result=macos_get_drag_event(ptr,&x,&y,&kind,buf,sizeof(buf),&pk,&source,&op,&tr);
  assert(result==0 && tr==1 && w.metalView.dragEventQueue.count==1 && buf[0]==0x55);
  const uint8_t *bytes; size_t length; const void *token,*again;
  @autoreleasepool {
   assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&token,&pk,&source,&op)==1);
  }
  assert(length==expected.length && memcmp(bytes,expected.bytes,length)==0);
  assert(x==12 && y==34 && kind==3 && pk==1);
  assert(macos_consume_drag_event(ptr,(const void *)1)==0);
  assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&again,&pk,&source,&op)==1 && token==again);
  char *full=malloc(length+1);
  assert(macos_get_drag_event(ptr,&x,&y,&kind,full,(int)length+1,&pk,&source,&op,&tr)==1);
  assert(tr==0 && memcmp(full,expected.bytes,length)==0 && full[length]==0); free(full);
  assert(macos_consume_drag_event(ptr,token)==0);
  const uint8_t nul[]={'a',0,0xE6,0xBC,0xA2};
  zenit_test_drag_enqueue(ptr,nul,sizeof(nul),3);
  assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&token,&pk,&source,&op)==1);
  assert(length==sizeof(nul) && memcmp(bytes,nul,length)==0 && source==123456789 && op==2);
  assert(macos_consume_drag_event(ptr,token)==1);
  zenit_test_drag_enqueue(ptr,(const uint8_t *)"",0,4);
  assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&token,&pk,&source,&op)==1);
  assert(kind==4 && length==0 && source==123456789 && op==2);
  assert(macos_consume_drag_event(ptr,token)==1);
  assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&token,&pk,&source,&op)==0);
  // Unpaired surrogate in a dropped string: delivered as U+FFFD, never -1
  // (which the Zig pump turns into BackendFailure and a dead App.run).
  const unichar lone[]={'/','x',0xDC00};
  NSString *loneText=[[NSString alloc] initWithCharacters:lone length:3];
  [w.metalView.dragEventQueue addObject:@{@"x":@1,@"y":@2,@"kind":@3,@"paths":loneText,@"payloadKind":@1,@"sourceToken":@7,@"operation":@1}];
  assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&token,&pk,&source,&op)==1);
  assert(length==5 && memcmp(bytes,"/x\xEF\xBF\xBD",5)==0);
  assert(macos_consume_drag_event(ptr,token)==1);
  assert(macos_peek_drag_event(ptr,&x,&y,&kind,&bytes,&length,&token,&pk,&source,&op)==0);
  zenit_test_drag_window_destroy(ptr);
  fprintf(stderr,"PASS: long drag retry, immutable peek lifetime, matching consumption, NUL and completion metadata\n");
 }
 return 0;
}
#endif
