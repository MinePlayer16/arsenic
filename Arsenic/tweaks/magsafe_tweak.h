//
//magsafe_tweak.h
//
#ifndef magsafe_tweak_h
#define magsafe_tweak_h
#include <stdbool.h>

// style: 0 = Native (Magsafe), 1 = Arsenic (Alternative charge animation)
bool magsafe_tweak_init_in_session(int style);
bool magsafe_tweak_show_animation(float batteryPercentage, int style);
bool magsafe_tweak_stop_in_session(void);
bool magsafe_tweak_hide_animation(void);
void magsafe_tweak_forget_remote_state(void);

#endif
