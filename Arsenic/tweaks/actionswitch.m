#import "actionswitch.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#include <stdio.h>

@interface NSObject (PrivateShortcutMethods)
- (id)initWithInput:(id)input presentationMode:(NSUInteger)mode;
- (id)initWithDescriptor:(id)descriptor runRequest:(id)request;
@end

static uint64_t gFlashlightController = 0;

// flashlight logic
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
    uint64_t currentLevel = r_msg2_main(gFlashlightController, "level", 0, 0, 0, 0);
    uint64_t newLevel = (currentLevel == 0) ? 1 : 0;
    r_msg2_main(gFlashlightController, "setLevel:", newLevel, 0, 0, 0);
    return true;
}

// open url scheme
bool actionswitch_open_url(const char* urlString) {
    uint64_t urlCls = r_class("NSURL");
    
    uint64_t remote_str = r_nsstr_retained(urlString);
    
    uint64_t url = r_msg2_main(urlCls, "URLWithString:", remote_str, 0, 0, 0);
    
    // shared UIApplication and open the url
    uint64_t appCls = r_class("UIApplication");
    uint64_t app = r_msg2_main(appCls, "sharedApplication", 0, 0, 0, 0);
    r_msg2_main(app, "openURL:", url, 0, 0, 0);
    
    r_msg2_main(remote_str, "release", 0, 0, 0, 0);
    
    return true;
}

static id g_active_shortcut_client = nil;

bool actionswitch_run_shortcut(const char* shortcutNameCStr) {
    if (!shortcutNameCStr) return false;
    
    uint64_t nsBundleCls = r_class("NSBundle");

    // load VoiceShortcutClient
    uint64_t vscPath = r_nsstr_retained("/System/Library/PrivateFrameworks/VoiceShortcutClient.framework");
    uint64_t vscBundle = r_msg2_main(nsBundleCls, "bundleWithPath:", vscPath, 0, 0, 0);
    if (vscBundle) r_msg2_main(vscBundle, "load", 0, 0, 0, 0);
    r_msg2_main(vscPath, "release", 0, 0, 0, 0);
    
    // load WorkflowKit
    uint64_t wkPath = r_nsstr_retained("/System/Library/PrivateFrameworks/WorkflowKit.framework");
    uint64_t wkBundle = r_msg2_main(nsBundleCls, "bundleWithPath:", wkPath, 0, 0, 0);
    if (wkBundle) r_msg2_main(wkBundle, "load", 0, 0, 0, 0);
    r_msg2_main(wkPath, "release", 0, 0, 0, 0);

    // NSString for shortcut name
    uint64_t remoteName = r_nsstr_retained(shortcutNameCStr);
    uint64_t descriptor = 0;
    
    uint64_t dbDescCls = r_class("WFWorkflowDatabaseRunDescriptor");
    if (dbDescCls) {
        uint64_t alloced = r_msg2_main(dbDescCls, "alloc", 0, 0, 0, 0);
        descriptor = r_msg2_main(alloced, "initWithName:", remoteName, 0, 0, 0);
    }
    
    
    if (!descriptor) {
        printf("[ActionSwitch] ERROR: Could not create run descriptor remotely.\n");
        r_msg2_main(remoteName, "release", 0, 0, 0, 0);
        return false;
    }

    // request
    uint64_t reqCls = r_class("WFWorkflowRunRequest");
    uint64_t reqAlloc = r_msg2_main(reqCls, "alloc", 0, 0, 0, 0);
    uint64_t request = r_msg2_main(reqAlloc, "initWithInput:presentationMode:", 0, 1, 0, 0);
    
    if (!request) {
        printf("[ActionSwitch] ERROR: Could not create WFWorkflowRunRequest remotely.\n");
        r_msg2_main(remoteName, "release", 0, 0, 0, 0);
        return false;
    }

    // create and start client
    uint64_t clientCls = r_class("WFWorkflowRunnerClient");
    uint64_t clientAlloc = r_msg2_main(clientCls, "alloc", 0, 0, 0, 0);
    uint64_t client = r_msg2_main(clientAlloc, "initWithDescriptor:runRequest:", descriptor, request, 0, 0);
    
    if (client) {
        r_msg2_main(client, "start", 0, 0, 0, 0);
        printf("[ActionSwitch] Successfully started background shortcut remotely: %s\n", shortcutNameCStr);
    } else {
        printf("[ActionSwitch] ERROR: Failed to initialize remote WFWorkflowRunnerClient.\n");
    }

    r_msg2_main(remoteName, "release", 0, 0, 0, 0);
    
    // we don't send "release" to the client object.  
    // it's in SpringBoard's memory so ARC doesn't destroy it before the shortcut finishes.
    return (client != 0);
}

bool actionswitch_trigger_action(const char* selectedAction) {
    if (!selectedAction) return false;
    
    if (strcmp(selectedAction, "Flashlight") == 0) {
        return actionswitch_toggle_flashlight();
    } else {
        return actionswitch_run_shortcut(selectedAction);
    }
}

bool actionswitch_stop_in_session(void) {
    if (gFlashlightController) r_msg2_main(gFlashlightController, "setLevel:", 0, 0, 0, 0);
    return true;
}

void actionswitch_forget_remote_state(void) {
    gFlashlightController = 0;
}
