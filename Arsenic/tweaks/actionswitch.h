#ifndef actionswitch_h
#define actionswitch_h

#include <stdbool.h>

bool actionswitch_toggle_flashlight(void);
bool actionswitch_stop_in_session(void);
void actionswitch_forget_remote_state(void);

#endif /* actionswitch_h */