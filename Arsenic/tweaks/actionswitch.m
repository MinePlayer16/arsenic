#import "actionswitch.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#include <stdio.h>

static uint64_t gFlashlightController = 0;

static bool resolve_flashlight_controller(void) {
    if (gFlashlightController) return true;
    
    uint64_t cls = r_class("SBUIFlashlightController");
    if (!r_is_objc_ptr(cls)) return false;
    
    uint64_t ctrl = r_msg2_main(cls, "sharedInstance", 0, 0, 0, 0);
    if (r_is_objc_ptr(ctrl)) {
        gFlashlightController = ctrl;
        return true;
    }
    return false;
}

bool actionswitch_toggle_flashlight(void) {
    if (!resolve_flashlight_controller()) return false;
    
    // read current level
    uint64_t currentLevel = r_msg2_main(gFlashlightController, "level", 0, 0, 0, 0);
    
    // toggle on or off (1 or 0)
    uint64_t newLevel = (currentLevel == 0) ? 1 : 0;
    r_msg2_main(gFlashlightController, "setLevel:", newLevel, 0, 0, 0);
    
    return true;
}

bool actionswitch_stop_in_session(void) {
    if (gFlashlightController) {
        r_msg2_main(gFlashlightController, "setLevel:", 0, 0, 0, 0);
    }
    return true;
}

void actionswitch_forget_remote_state(void) {
    gFlashlightController = 0;
}