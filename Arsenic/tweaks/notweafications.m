//
//  notweafications.m
//  RemoteCall notifications coloring
//

#import "notweafications.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import <string.h>
#import <stdlib.h>

static const int kNotweaficationsBgTag = 0x1071F1C;
static const double kNotweaficationsCornerRadius = 16.0;

// cached pointers
static uint64_t g_notweafications_clvc = 0;
static uint64_t g_PLPlatterView_class = 0;
static uint64_t g_MTMaterialView_class = 0;
static uint64_t g_UIVisualEffectView_class = 0;
static uint64_t g_UIView_class = 0;
static uint64_t g_UIColor_class = 0;

static bool notweafications_initialize_classes(void) {
    if (!g_UIView_class) g_UIView_class = r_class("UIView");
    if (!g_UIColor_class) g_UIColor_class = r_class("UIColor");
    if (!g_PLPlatterView_class) g_PLPlatterView_class = r_class("PLPlatterView");
    if (!g_MTMaterialView_class) g_MTMaterialView_class = r_class("MTMaterialView");
    if (!g_UIVisualEffectView_class) g_UIVisualEffectView_class = r_class("UIVisualEffectView");
    return g_UIView_class && g_UIColor_class;
}

#define NW_MAX_SEEN 256
typedef struct {
    uint64_t request;
    uint64_t cell;
} NWSeenEntry;

static NWSeenEntry g_seen[NW_MAX_SEEN];
static size_t g_seen_next = 0;

static bool nw_seen_same_cell(uint64_t request, uint64_t cell) {
    for (size_t i = 0; i < NW_MAX_SEEN; i++) {
        if (g_seen[i].request == request && g_seen[i].cell == cell) {
            return true;
        }
    }
    return false;
}

static void nw_mark_seen(uint64_t request, uint64_t cell) {
    g_seen[g_seen_next].request = request;
    g_seen[g_seen_next].cell = cell;
    g_seen_next = (g_seen_next + 1) % NW_MAX_SEEN;
}

static void nw_clear_seen(void) {
    memset(g_seen, 0, sizeof(g_seen));
    g_seen_next = 0;
}

// dictionary snapshot
#define NW_MAX_SNAPSHOT 1024

typedef struct {
    uint64_t request;
    uint64_t cell;
} NWSnapshotEntry;

static size_t nw_snapshot_cells_dictionary(uint64_t cellsDict,
                                           NWSnapshotEntry *entries,
                                           size_t capacity) {
    if (!r_is_objc_ptr(cellsDict) || !entries || capacity == 0) return 0;

     // first it copies it to springboard's main thread, NSDictionary is immutable.
    uint64_t stableDict = r_msg2_main(cellsDict, "copy", 0, 0, 0, 0);
    if (!r_is_objc_ptr(stableDict)) return 0;

    size_t result = 0;
    uint64_t remoteKeys = 0;
    uint64_t remoteValues = 0;
    uint64_t *localKeys = NULL;
    uint64_t *localValues = NULL;

    uint64_t count = r_msg2_main(stableDict, "count", 0, 0, 0, 0);
    if (count == 0 || count > capacity) goto cleanup;

    uint64_t bytes = count * sizeof(uint64_t);
    remoteKeys = r_dlsym_call(R_TIMEOUT, "malloc", bytes, 0, 0, 0, 0, 0, 0, 0);
    remoteValues = r_dlsym_call(R_TIMEOUT, "malloc", bytes, 0, 0, 0, 0, 0, 0, 0);
    if (!remoteKeys || !remoteValues) goto cleanup;

    r_msg2_main(stableDict, "getObjects:andKeys:count:", remoteValues, remoteKeys, count, 0);

    localKeys = calloc((size_t)count, sizeof(uint64_t));
    localValues = calloc((size_t)count, sizeof(uint64_t));
    if (!localKeys || !localValues) goto cleanup;

    size_t copyBytes = (size_t)count * sizeof(uint64_t);
    if (!remote_read(remoteKeys, localKeys, copyBytes) ||
        !remote_read(remoteValues, localValues, copyBytes)) {
        goto cleanup;
    }

    for (size_t i = 0; i < (size_t)count; i++) {
        entries[i].request = localKeys[i];
        entries[i].cell = localValues[i];
    }
    result = (size_t)count;

cleanup:
    free(localKeys);
    free(localValues);
    if (remoteKeys) r_free(remoteKeys);
    if (remoteValues) r_free(remoteValues);
    r_msg2(stableDict, "release", 0, 0, 0, 0);
    return result;
}

static bool notweafications_object_class_name(uint64_t obj, char *out, size_t outLen) {
    if (!r_is_objc_ptr(obj) || !out || outLen == 0) return false;
    out[0] = '\0';

    uint64_t cls = r_dlsym_call(R_TIMEOUT, "object_getClass", obj, 0, 0, 0, 0, 0, 0, 0);
    if (!r_is_objc_ptr(cls)) return false;
    
    uint64_t name = r_dlsym_call(R_TIMEOUT, "class_getName", cls, 0, 0, 0, 0, 0, 0, 0);
    if (!name) return false;

    uint64_t heapName = r_dlsym_call(R_TIMEOUT, "strdup", name, 0, 0, 0, 0, 0, 0, 0);
    if (!heapName) return false;
    
    bool ok = remote_read(heapName, out, outLen - 1);
    r_free(heapName);
    
    if (ok) out[outLen - 1] = '\0';
    return ok && out[0] != '\0';
}

enum {
    NWUserInterfaceStyleUnspecified = 0,
    NWUserInterfaceStyleLight = 1,
    NWUserInterfaceStyleDark = 2
};

static uint64_t notweafications_color_for_bundle(const char *bundle,
                                                  bool *outDarkBackground) {
    double r = 1.0, g = 1.0, b = 1.0, a = 1.0;

    if (bundle && bundle[0]) {
        NSString *bundleStr = [NSString stringWithUTF8String:bundle];
        NSArray *apps = [[NSUserDefaults standardUserDefaults] arrayForKey:@"NotweaficationsAppColors"];
        
        for (NSDictionary *app in apps) {
            if ([app[@"bundleID"] isEqualToString:bundleStr]) {
                NSString *hex = app[@"hexColor"];
                if (hex.length > 0) {
                    // hex to rgb color
                    NSString *cleanHex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
                    unsigned int rgb = 0;
                    NSScanner *scanner = [NSScanner scannerWithString:cleanHex];
                    [scanner scanHexInt:&rgb];
                    
                    r = ((rgb >> 16) & 0xFF) / 255.0;
                    g = ((rgb >> 8) & 0xFF) / 255.0;
                    b = (rgb & 0xFF) / 255.0;
                    break;
                }
            }
        }
    }

    // calculates brightness for contrast
    double brightness = (0.299 * r) + (0.587 * g) + (0.114 * b);
    if (outDarkBackground) {
        *outDarkBackground = brightness < 0.45;
    }

    return r_msg2_main_raw(g_UIColor_class, "colorWithRed:green:blue:alpha:",
                           &r, sizeof(double), &g, sizeof(double),
                           &b, sizeof(double), &a, sizeof(double));
}

static void notweafications_apply_contrast_style(uint64_t platter,
                                                  bool darkBackground) {
    if (!r_is_objc_ptr(platter)) return;

    uint64_t style = darkBackground
        ? NWUserInterfaceStyleDark
        : NWUserInterfaceStyleLight;

    r_msg2_main(platter, "setOverrideUserInterfaceStyle:", style, 0, 0, 0);
}

static uint64_t notweafications_extract_platter(uint64_t cell) {
    if (!r_is_objc_ptr(cell)) return 0;
    
    uint64_t contentVC = r_msg2_main(cell, "contentViewController", 0, 0, 0, 0);
    if (!r_is_objc_ptr(contentVC)) return 0;
    
    uint64_t lookView = r_ivar_value(contentVC, "_lookView");
    if (!r_is_objc_ptr(lookView)) lookView = r_msg2_main(contentVC, "_lookView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(lookView)) return 0;
    
    uint64_t subviews = r_msg2_main(lookView, "subviews", 0, 0, 0, 0);
    if (r_is_objc_ptr(subviews)) {
        uint64_t count = r_msg2_main(subviews, "count", 0, 0, 0, 0);
        for (uint64_t i = 0; i < count; i++) {
            uint64_t sub = r_msg2_main(subviews, "objectAtIndex:", i, 0, 0, 0);
            if (g_PLPlatterView_class && r_msg2(sub, "isKindOfClass:", g_PLPlatterView_class, 0, 0, 0)) {
                return sub;
            }
        }
    }
    return 0;
}

static uint64_t notweafications_find_clvc_recursive(uint64_t vc, int depth) {
    if (!r_is_objc_ptr(vc) || depth > 6) return 0;
    
    char cls[96] = {0};
    notweafications_object_class_name(vc, cls, sizeof(cls));
    
    if (strstr(cls, "CombinedListViewController") || strstr(cls, "StructuredListViewController")) {
        if (r_responds_main(vc, "listModel")) return vc;
    }
    
    if (r_responds_main(vc, "notificationListViewController")) {
        uint64_t child = r_msg2_main(vc, "notificationListViewController", 0, 0, 0, 0);
        if (r_is_objc_ptr(child)) return child;
    }
    if (r_responds_main(vc, "combinedListViewController")) {
        uint64_t child = r_msg2_main(vc, "combinedListViewController", 0, 0, 0, 0);
        if (r_is_objc_ptr(child)) {
            uint64_t hit = notweafications_find_clvc_recursive(child, depth + 1);
            if (hit) return hit;
        }
    }
    if (r_responds_main(vc, "mainPageContentViewController")) {
        uint64_t child = r_msg2_main(vc, "mainPageContentViewController", 0, 0, 0, 0);
        if (r_is_objc_ptr(child)) {
            uint64_t hit = notweafications_find_clvc_recursive(child, depth + 1);
            if (hit) return hit;
        }
    }
    if (r_responds_main(vc, "presentedViewController")) {
        uint64_t presented = r_msg2_main(vc, "presentedViewController", 0, 0, 0, 0);
        if (r_is_objc_ptr(presented)) {
            uint64_t hit = notweafications_find_clvc_recursive(presented, depth + 1);
            if (hit) return hit;
        }
    }
    if (r_responds_main(vc, "childViewControllers")) {
        uint64_t children = r_msg2_main(vc, "childViewControllers", 0, 0, 0, 0);
        if (r_is_objc_ptr(children)) {
            uint64_t count = r_msg2_main(children, "count", 0, 0, 0, 0);
            for (uint64_t i = 0; i < count && i < 10; i++) {
                uint64_t child = r_msg2_main(children, "objectAtIndex:", i, 0, 0, 0);
                uint64_t hit = notweafications_find_clvc_recursive(child, depth + 1);
                if (hit) return hit;
            }
        }
    }
    return 0;
}

static uint64_t notweafications_find_clvc(void) {
    if (r_is_objc_ptr(g_notweafications_clvc)) return g_notweafications_clvc;
    
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_is_objc_ptr(UIApplication) ? r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0) : 0;
    uint64_t windows = r_is_objc_ptr(app) ? r_msg2_main(app, "windows", 0, 0, 0, 0) : 0;
    uint64_t count = r_is_objc_ptr(windows) ? r_msg2_main(windows, "count", 0, 0, 0, 0) : 0;
    
    for (uint64_t i = 0; i < count; i++) {
        uint64_t win = r_msg2_main(windows, "objectAtIndex:", count - 1 - i, 0, 0, 0);
        uint64_t root = r_responds_main(win, "rootViewController") ? 
                        r_msg2_main(win, "rootViewController", 0, 0, 0, 0) : 0;
        
        uint64_t hit = notweafications_find_clvc_recursive(root, 0);
        if (hit) {
            g_notweafications_clvc = hit;
            return hit;
        }
    }
    return 0;
}

bool notweafications_apply_in_session(void) {
    notweafications_initialize_classes();

    uint64_t clvc = notweafications_find_clvc(); 
    if (!r_is_objc_ptr(clvc)) return false;
    
    uint64_t listModel = r_msg2_main(clvc, "listModel", 0, 0, 0, 0);
    if (!r_is_objc_ptr(listModel)) return false;

    uint64_t listCache = r_msg2_main(listModel, "notificationListCache", 0, 0, 0, 0);
    if (!r_is_objc_ptr(listCache)) return false;

    uint64_t cellsDict = r_msg2_main(listCache, "notificationListCellsForRequests", 0, 0, 0, 0);
    if (!r_is_objc_ptr(cellsDict)) return false;

    NWSnapshotEntry snapshot[NW_MAX_SNAPSHOT] = {0};
    size_t count = nw_snapshot_cells_dictionary(cellsDict,
                                                snapshot,
                                                NW_MAX_SNAPSHOT);
    if (count == 0) return true;

    for (size_t i = 0; i < count; i++) {
        uint64_t request = snapshot[i].request;
        uint64_t cell = snapshot[i].cell;
        if (!r_is_objc_ptr(request) || !r_is_objc_ptr(cell)) continue;

        if (nw_seen_same_cell(request, cell)) {
            continue;
        }
        
        char bundle[128] = {0};
        uint64_t sectionId = r_msg2(request, "sectionIdentifier", 0, 0, 0, 0);
        r_read_nsstring(sectionId, bundle, sizeof(bundle));
        
        bool darkBackground = false;
        uint64_t targetColor =
            notweafications_color_for_bundle(bundle, &darkBackground);
        uint64_t platter = notweafications_extract_platter(cell);
        if (!r_is_objc_ptr(platter) || !r_is_objc_ptr(targetColor)) continue;

        notweafications_apply_contrast_style(platter, darkBackground);
        
        uint64_t existingBg = r_msg2_main(platter, "viewWithTag:", kNotweaficationsBgTag, 0, 0, 0);
        if (r_is_objc_ptr(existingBg)) {
            r_msg2_main(existingBg, "setBackgroundColor:", targetColor, 0, 0, 0);
            r_msg2_main(existingBg, "setHidden:", 0, 0, 0, 0);
            nw_mark_seen(request, cell);
            continue;
        }
        
        // this hides Apple's MTMaterialView blurs via direct ivar (fastest) or loop (fallback)
        bool materialHidden = false;
        uint64_t bgIvar = r_ivar_value(platter, "_backgroundView");
        if (r_is_objc_ptr(bgIvar)) {
            r_msg2_main(bgIvar, "setHidden:", 1, 0, 0, 0);
            materialHidden = true;
        } 
        
        if (!materialHidden) {
            uint64_t customContentView = r_ivar_value(platter, "_customContentView");
            uint64_t pSubviews = r_msg2_main(platter, "subviews", 0, 0, 0, 0);
            uint64_t pCount = r_is_objc_ptr(pSubviews) ? r_msg2_main(pSubviews, "count", 0, 0, 0, 0) : 0;
            
            for (uint64_t j = 0; j < pCount; j++) {
                uint64_t pSub = r_msg2_main(pSubviews, "objectAtIndex:", j, 0, 0, 0);
                if (pSub == customContentView) continue;
                
                if ((g_MTMaterialView_class && r_msg2(pSub, "isKindOfClass:", g_MTMaterialView_class, 0, 0, 0)) ||
                    (g_UIVisualEffectView_class && r_msg2(pSub, "isKindOfClass:", g_UIVisualEffectView_class, 0, 0, 0))) {
                    r_msg2_main(pSub, "setHidden:", 1, 0, 0, 0);
                }
            }
        }
        
        // inject custom color
        uint64_t bgView = r_msg2_main(r_msg2_main(g_UIView_class, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);
        
        r_msg2_main(bgView, "setTag:", kNotweaficationsBgTag, 0, 0, 0);
        r_msg2_main(bgView, "setBackgroundColor:", targetColor, 0, 0, 0);
        r_msg2_main(bgView, "setAutoresizingMask:", (1<<1) | (1<<4), 0, 0, 0);
        
        uint64_t bgLayer = r_msg2_main(bgView, "layer", 0, 0, 0, 0);
        double cornerRadius = kNotweaficationsCornerRadius;
        r_msg2_main_raw(bgLayer, "setCornerRadius:",
                        &cornerRadius, sizeof(cornerRadius),
                        NULL, 0, NULL, 0, NULL, 0);
        
        struct { double x, y, w, h; } bounds = {0};
        r_msg2_main_struct_ret(platter, "bounds", &bounds, sizeof(bounds), NULL, 0, NULL, 0, NULL, 0, NULL, 0);
        r_msg2_main_raw(bgView, "setFrame:", &bounds, sizeof(bounds), NULL, 0, NULL, 0, NULL, 0);
        
        r_msg2_main(platter, "insertSubview:atIndex:", bgView, 0, 0, 0);
        r_msg2_main(bgView, "release", 0, 0, 0, 0);

        nw_mark_seen(request, cell);
    }
    
    return true;
}

bool notweafications_stop_in_session(void) {
    uint64_t clvc = notweafications_find_clvc(); 
    if (!r_is_objc_ptr(clvc)) return false;
    
    uint64_t listModel = r_msg2_main(clvc, "listModel", 0, 0, 0, 0);
    if (!r_is_objc_ptr(listModel)) return false;

    uint64_t listCache = r_msg2_main(listModel, "notificationListCache", 0, 0, 0, 0);
    if (!r_is_objc_ptr(listCache)) return false;

    uint64_t cellsDict = r_msg2_main(listCache, "notificationListCellsForRequests", 0, 0, 0, 0);
    if (!r_is_objc_ptr(cellsDict)) return false;

    NWSnapshotEntry snapshot[NW_MAX_SNAPSHOT] = {0};
    size_t count = nw_snapshot_cells_dictionary(cellsDict,
                                                snapshot,
                                                NW_MAX_SNAPSHOT);
    notweafications_initialize_classes();

    // reverse the style for all active notifications
    for (size_t i = 0; i < count; i++) {
        uint64_t cell = snapshot[i].cell;
        if (!r_is_objc_ptr(cell)) continue;
        
        uint64_t platter = notweafications_extract_platter(cell);
        if (!r_is_objc_ptr(platter)) continue;
        
        uint64_t bgView = r_msg2_main(platter, "viewWithTag:", kNotweaficationsBgTag, 0, 0, 0);
        if (r_is_objc_ptr(bgView)) {
            r_msg2_main(bgView, "removeFromSuperview", 0, 0, 0, 0);
        }
        
        r_msg2_main(platter, "setOverrideUserInterfaceStyle:",
                    NWUserInterfaceStyleUnspecified, 0, 0, 0);

        uint64_t bgIvar = r_ivar_value(platter, "_backgroundView");
        if (r_is_objc_ptr(bgIvar)) {
            r_msg2_main(bgIvar, "setHidden:", 0, 0, 0, 0);
        } else {
            uint64_t customContentView = r_ivar_value(platter, "_customContentView");
            uint64_t pSubviews = r_msg2_main(platter, "subviews", 0, 0, 0, 0);
            uint64_t pCount = r_is_objc_ptr(pSubviews) ? r_msg2_main(pSubviews, "count", 0, 0, 0, 0) : 0;
            for (uint64_t j = 0; j < pCount; j++) {
                uint64_t pSub = r_msg2_main(pSubviews, "objectAtIndex:", j, 0, 0, 0);
                if (pSub == customContentView) continue; 
                if ((g_MTMaterialView_class && r_msg2(pSub, "isKindOfClass:", g_MTMaterialView_class, 0, 0, 0)) ||
                    (g_UIVisualEffectView_class && r_msg2(pSub, "isKindOfClass:", g_UIVisualEffectView_class, 0, 0, 0))) {
                    r_msg2_main(pSub, "setHidden:", 0, 0, 0, 0); 
                }
            }
        }
    }
    
    nw_clear_seen();
    return true;
}

void notweafications_forget_remote_state(void) {
    g_notweafications_clvc = 0;
    g_PLPlatterView_class = 0;
    g_MTMaterialView_class = 0;
    g_UIVisualEffectView_class = 0;
    g_UIView_class = 0;
    g_UIColor_class = 0;
    
    nw_clear_seen();
}
