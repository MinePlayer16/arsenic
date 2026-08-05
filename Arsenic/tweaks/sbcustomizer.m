//
//  sbcustomizer.m
//

#import "sbcustomizer.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import <stdio.h>
#import <string.h>
#import <unistd.h>
#import "../LogTextView.h"

static int clamp(int v, int lo, int hi) {
    if (v < lo) return lo;
    if (v > hi) return hi;
    return v;
}

static uint64_t try_msg0(uint64_t obj, const char *selName)
{
    if (!r_is_objc_ptr(obj) || !r_responds(obj, selName)) return 0;
    return r_msg2(obj, selName, 0, 0, 0, 0);
}

static uint64_t retain_remote_object(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return 0;
    uint64_t retained = r_dlsym_call(
        R_TIMEOUT, "CFRetain", obj, 0, 0, 0, 0, 0, 0, 0);
    return r_is_objc_ptr(retained) ? retained : 0;
}

static void release_remote_object(uint64_t obj)
{
    if (!r_is_objc_ptr(obj)) return;
    r_dlsym_call(R_TIMEOUT, "CFRelease", obj, 0, 0, 0, 0, 0, 0, 0);
}

static void disable_list_autofit(uint64_t listView, const char *tag)
{
    if (!r_is_objc_ptr(listView) || !r_responds(listView, "setAutomaticallyAdjustsLayoutMetricsToFit:")) return;
    r_msg2(listView, "setAutomaticallyAdjustsLayoutMetricsToFit:", 0, 0, 0, 0);
    printf("[SBC] v3: %s autoFit=NO\n", tag);
}

static uint64_t list_view_model(uint64_t listView)
{
    uint64_t model = try_msg0(listView, "model");
    if (!model) model = try_msg0(listView, "iconListModel");
    if (!model) model = try_msg0(listView, "displayedModel");
    return model;
}

static bool patch_list_model_grid(uint64_t listView, const char *tag, int cols, int rows)
{
    if (!r_is_objc_ptr(listView)) return false;

    uint64_t model = list_view_model(listView);
    if (!r_is_objc_ptr(model) || !r_responds(model, "gridSize")) {
        printf("[SBC] v3: %s missing grid model\n", tag);
        return false;
    }

    uint64_t newGrid = (((uint64_t)rows & 0xffffULL) << 16) | ((uint64_t)cols & 0xffffULL);
    uint64_t oldGrid = r_msg2(model, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;

    if (r_responds(model, "setGridSize:")) {
        r_msg2(model, "setGridSize:", newGrid, 0, 0, 0);
    } else if (r_responds(model, "changeGridSize:options:")) {
        r_msg2(model, "changeGridSize:options:", newGrid, 0, 0, 0);
    } else {
        printf("[SBC] v3: %s model lacks grid setter\n", tag);
        return false;
    }

    uint64_t afterGrid = r_msg2(model, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;
    printf("[SBC] v3: %s model gridSize 0x%llx -> 0x%llx\n", tag, oldGrid, afterGrid);
    return afterGrid == newGrid;
}

static void patch_dock(uint64_t iconCtrl, int dockIcons)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    if (!mgr) { printf("[SBC] dock: nil iconManager\n"); return; }
    usleep(50000);

    uint64_t dock = try_msg0(mgr, "dockListView");
    if (!dock) dock = try_msg0(iconCtrl, "dockListView");
    if (!dock) { printf("[SBC] dock: nil dockListView\n"); return; }
    disable_list_autofit(dock, "dockListView");
    usleep(50000);

    uint64_t model = try_msg0(dock, "model");
    if (!model) model = try_msg0(dock, "iconListModel");
    if (!model) model = try_msg0(dock, "displayedModel");
    if (model && r_responds(model, "gridSize") && r_responds(model, "setGridSize:")) {
        uint64_t oldGrid = r_msg2(model, "gridSize", 0, 0, 0, 0) & 0xffffffffULL;
        uint64_t newGrid = (oldGrid & 0xffff0000ULL) | (uint64_t)dockIcons;
        usleep(50000);
        r_msg2(model, "setGridSize:", newGrid, 0, 0, 0);
        printf("[SBC] dock: gridSize 0x%llx -> 0x%llx\n", oldGrid, newGrid);
    }
    usleep(50000);

    uint64_t layout = try_msg0(dock, "layout");
    if (layout) {
        usleep(50000);
        uint64_t cfg = try_msg0(layout, "layoutConfiguration");
        if (cfg && r_responds(cfg, "setNumberOfPortraitColumns:")) {
            usleep(50000);
            r_msg2(cfg, "setNumberOfPortraitColumns:", (uint64_t)dockIcons, 0, 0, 0);
            printf("[SBC] dock: portraitColumns -> %d\n", dockIcons);
        }
    }
    usleep(50000);

    if (r_responds(dock, "setNeedsLayout")) {
        uint64_t selSetNeedsLayout = r_sel("setNeedsLayout");
        r_perform_main(dock, selSetNeedsLayout, 0, false);
    }
}

// Icon arrays are transient: changing a grid or moving an icon can replace
// them between two RemoteCall messages. Return an explicitly retained array
// so a following count/objectAtIndex: cannot target a deallocated instance.
static uint64_t model_icons_retained(uint64_t model)
{
    uint64_t stableModel = retain_remote_object(model);
    if (!stableModel) return 0;
    uint64_t icons = try_msg0(stableModel, "icons");
    if (!icons) icons = try_msg0(stableModel, "allIcons");
    if (!icons) icons = try_msg0(stableModel, "visibleIcons");
    if (!icons) icons = try_msg0(stableModel, "displayedIcons");
    uint64_t retainedIcons = retain_remote_object(icons);
    release_remote_object(stableModel);
    return retainedIcons;
}

static bool icon_matches_bundle(uint64_t icon, const char *bundleID)
{
    if (!r_is_objc_ptr(icon) || !bundleID || !bundleID[0]) return false;

    // Only use the known-safe SBApplication bundle path. Some legacy icon
    // identifier getters advertise Objective-C-looking return values but
    // actually return private payloads; probing those with
    // respondsToSelector: can terminate SpringBoard with a PAC exception.
    if (!r_responds(icon, "application")) return false;
    uint64_t app = r_msg2(icon, "application", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app) || !r_responds(app, "bundleIdentifier")) return false;
    uint64_t value = r_msg2(app, "bundleIdentifier", 0, 0, 0, 0);
    char actual[192] = {0};
    return r_is_objc_ptr(value) &&
           r_read_nsstring(value, actual, sizeof(actual)) &&
           strcmp(actual, bundleID) == 0;
}

static uint64_t find_icon_in_array_by_bundle(uint64_t icons, uint64_t listView,
                                             const char *bundleID,
                                             uint64_t *indexOut)
{
    if (!r_is_objc_ptr(icons) || !r_responds(icons, "count") ||
        !r_responds(icons, "objectAtIndex:")) return 0;
    uint64_t count = r_msg2_main(icons, "count", 0, 0, 0, 0);
    uint64_t limit = count < 256 ? count : 256;
    for (uint64_t i = 0; i < limit; i++) {
        uint64_t candidate = r_msg2_main(icons, "objectAtIndex:", i, 0, 0, 0);
        bool matched = icon_matches_bundle(candidate, bundleID);
        if (!matched && r_is_objc_ptr(listView)) {
            const char *viewSels[] = {
                "displayedIconViewForIcon:",
                "iconViewForIcon:",
                "_iconViewForIcon:",
                NULL,
            };
            for (int s = 0; viewSels[s] && !matched; s++) {
                if (!r_responds_main(listView, viewSels[s])) continue;
                uint64_t iconView = r_msg2_main(
                    listView, viewSels[s], candidate, 0, 0, 0);
                uint64_t displayedIcon = try_msg0(iconView, "icon");
                matched = icon_matches_bundle(displayedIcon, bundleID);
            }
        }
        if (!matched) continue;
        if (indexOut) *indexOut = i;
        return candidate;
    }
    return 0;
}

static bool model_can_remove(uint64_t model)
{
    return r_responds(model, "removeIcon:") || r_responds(model, "removeIconAtIndex:");
}

static bool model_can_insert(uint64_t model)
{
    return r_responds(model, "insertIcon:atIndex:") || r_responds(model, "addIcon:");
}

static bool remove_icon_from_model(uint64_t model, uint64_t index, uint64_t icon)
{
    if (!model_can_remove(model)) return false;
    if (r_responds(model, "removeIcon:")) {
        r_msg2_main(model, "removeIcon:", icon, 0, 0, 0);
    } else {
        r_msg2_main(model, "removeIconAtIndex:", index, 0, 0, 0);
    }
    return true;
}

static bool insert_icon_into_model(uint64_t model, uint64_t index, uint64_t icon)
{
    if (!model_can_insert(model)) return false;
    if (r_responds(model, "insertIcon:atIndex:")) {
        r_msg2_main(model, "insertIcon:atIndex:", icon, index, 0, 0);
    } else {
        r_msg2_main(model, "addIcon:", icon, 0, 0, 0);
    }
    return true;
}

static uint64_t icon_array_count(uint64_t model);

static bool auto_add_app_to_dock(uint64_t iconCtrl, int dockIcons, const char *bundleID)
{
    if (!bundleID || !bundleID[0]) {
        printf("[SBC:DOCKAPP] no bundle identifier selected\n");
        return false;
    }

    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    uint64_t dockView = try_msg0(mgr, "dockListView");
    if (!dockView) dockView = try_msg0(iconCtrl, "dockListView");
    uint64_t dockModel = list_view_model(dockView);
    if (!r_is_objc_ptr(dockModel)) {
        printf("[SBC:DOCKAPP] dock model unavailable\n");
        return false;
    }

    uint64_t iconModel = try_msg0(mgr, "iconModel");
    if (!iconModel) iconModel = try_msg0(iconCtrl, "model");
    if (!iconModel) iconModel = try_msg0(iconCtrl, "iconModel");
    if (!r_is_objc_ptr(iconModel) ||
        !r_responds(iconModel, "applicationIconForBundleIdentifier:")) {
        printf("[SBC:DOCKAPP] application icon lookup unavailable\n");
        return false;
    }

    uint64_t bundle = r_nsstr_retained(bundleID);
    uint64_t icon = bundle
        ? r_msg2_main(iconModel, "applicationIconForBundleIdentifier:", bundle, 0, 0, 0)
        : 0;
    release_remote_object(bundle);
    if (!r_is_objc_ptr(icon)) {
        printf("[SBC:DOCKAPP] app not found bundle=%s\n", bundleID);
        return false;
    }

    uint64_t dockIconsArray = model_icons_retained(dockModel);
    uint64_t dockMatchIndex = 0;
    uint64_t dockMatch = find_icon_in_array_by_bundle(
        dockIconsArray, dockView, bundleID, &dockMatchIndex);
    if (r_is_objc_ptr(dockMatch)) {
        release_remote_object(dockIconsArray);
        printf("[SBC:DOCKAPP] already in dock bundle=%s\n", bundleID);
        return true;
    }
    uint64_t dockCount = r_is_objc_ptr(dockIconsArray)
        ? r_msg2_main(dockIconsArray, "count", 0, 0, 0, 0) : 0;
    release_remote_object(dockIconsArray);
    if (dockCount >= (uint64_t)dockIcons) {
        printf("[SBC:DOCKAPP] dock full count=%llu capacity=%d bundle=%s\n",
               dockCount, dockIcons, bundleID);
        return false;
    }

    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    uint64_t sourceModel = 0;
    uint64_t sourceIndex = 0;
    uint64_t sourcePage = UINT64_MAX;
    if (r_is_objc_ptr(rootFolder) &&
        r_responds(rootFolder, "iconListViewCount") &&
        r_responds(rootFolder, "iconListViewAtIndex:")) {
        uint64_t pages = r_msg2_main(rootFolder, "iconListViewCount", 0, 0, 0, 0);
        uint64_t limit = pages < 64 ? pages : 64;
        for (uint64_t i = 0; i < limit; i++) {
            uint64_t listView = r_msg2_main(rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
            uint64_t candidate = list_view_model(listView);
            uint64_t icons = model_icons_retained(candidate);
            uint64_t matched = find_icon_in_array_by_bundle(
                icons, listView, bundleID, &sourceIndex);
            if (!r_is_objc_ptr(matched)) {
                release_remote_object(icons);
                continue;
            }
            uint64_t retainedIcon = retain_remote_object(matched);
            uint64_t retainedModel = retain_remote_object(candidate);
            release_remote_object(icons);
            if (!retainedIcon || !retainedModel) {
                release_remote_object(retainedIcon);
                release_remote_object(retainedModel);
                continue;
            }
            icon = retainedIcon;
            sourceModel = retainedModel;
            sourcePage = i;
            break;
        }
    }
    if (!r_is_objc_ptr(sourceModel)) {
        printf("[SBC:DOCKAPP] top-level source not found; refusing duplicate insertion bundle=%s\n",
               bundleID);
        return false;
    }

    bool canRemove = model_can_remove(sourceModel);
    bool canInsert = model_can_insert(dockModel);
    if (!canRemove || !canInsert) {
        printf("[SBC:DOCKAPP] mutation selectors unavailable remove=%d insert=%d\n",
               canRemove, canInsert);
        release_remote_object(sourceModel);
        release_remote_object(icon);
        return false;
    }

    uint64_t sourceCountBefore = icon_array_count(sourceModel);
    if (!remove_icon_from_model(sourceModel, sourceIndex, icon)) {
        printf("[SBC:DOCKAPP] source removal selector unavailable\n");
        release_remote_object(sourceModel);
        release_remote_object(icon);
        return false;
    }
    release_remote_object(sourceModel);

    // Removing an icon can rebuild every list model. Reacquire the Dock
    // model before inserting instead of messaging the pre-removal pointer.
    mgr = try_msg0(iconCtrl, "iconManager");
    rootFolder = try_msg0(mgr, "rootFolderController");
    uint64_t sourceCountAfter = UINT64_MAX;
    for (int attempt = 0; attempt < 5; attempt++) {
        uint64_t sourceView = r_msg2_main(
            rootFolder, "iconListViewAtIndex:", sourcePage, 0, 0, 0);
        sourceCountAfter = icon_array_count(list_view_model(sourceView));
        if (sourceCountBefore != UINT64_MAX &&
            sourceCountAfter + 1 == sourceCountBefore) break;
        usleep(5000);
        mgr = try_msg0(iconCtrl, "iconManager");
        rootFolder = try_msg0(mgr, "rootFolderController");
    }
    if (sourceCountBefore == UINT64_MAX ||
        sourceCountAfter + 1 != sourceCountBefore) {
        printf("[SBC:DOCKAPP] page[%llu] removal count mismatch %llu -> %llu; aborting Dock insert\n",
               sourcePage, sourceCountBefore, sourceCountAfter);
        release_remote_object(icon);
        return false;
    }

    dockView = try_msg0(mgr, "dockListView");
    if (!dockView) dockView = try_msg0(iconCtrl, "dockListView");
    dockModel = list_view_model(dockView);
    bool inserted = insert_icon_into_model(dockModel, dockCount, icon);
    mgr = try_msg0(iconCtrl, "iconManager");
    dockView = try_msg0(mgr, "dockListView");
    dockModel = list_view_model(dockView);
    uint64_t verifyIcons = model_icons_retained(dockModel);
    inserted = inserted && r_is_objc_ptr(find_icon_in_array_by_bundle(
        verifyIcons, dockView, bundleID, NULL)) &&
        icon_array_count(dockModel) == dockCount + 1;
    release_remote_object(verifyIcons);
    if (!inserted) {
        printf("[SBC:DOCKAPP] insertion failed; restoring page[%llu]\n", sourcePage);
        rootFolder = try_msg0(mgr, "rootFolderController");
        uint64_t restoreView = r_msg2_main(
            rootFolder, "iconListViewAtIndex:", sourcePage, 0, 0, 0);
        insert_icon_into_model(list_view_model(restoreView), sourceIndex, icon);
        release_remote_object(icon);
        return false;
    }

    if (r_responds(dockView, "setNeedsLayout")) {
        r_perform_main(dockView, r_sel("setNeedsLayout"), 0, false);
    }
    release_remote_object(icon);
    printf("[SBC:DOCKAPP] moved bundle=%s to dock index=%llu\n", bundleID, dockCount);
    return true;
}

static int patch_homescreen_list_models_v3(uint64_t mgr, int cols, int rows)
{
    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder)) {
        printf("[SBC] v3: nil rootFolderController\n");
        return 0;
    }

    int touched = 0;
    if (r_responds(rootFolder, "iconListViewCount") &&
        r_responds(rootFolder, "iconListViewAtIndex:")) {
        uint64_t count = r_msg2(rootFolder, "iconListViewCount", 0, 0, 0, 0);
        uint64_t limit = count < 64 ? count : 64;
        printf("[SBC] v3: iconListViewCount=%llu\n", count);
        for (uint64_t i = 0; i < limit; i++) {
            uint64_t listView = r_msg2(rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
            if (!r_is_objc_ptr(listView)) continue;

            char tag[32];
            snprintf(tag, sizeof(tag), "page[%llu]", i);
            disable_list_autofit(listView, tag);
            if (patch_list_model_grid(listView, tag, cols, rows)) touched++;
        }
    } else if (r_responds(rootFolder, "currentIconListView")) {
        uint64_t current = r_msg2(rootFolder, "currentIconListView", 0, 0, 0, 0);
        disable_list_autofit(current, "currentIconListView");
        if (patch_list_model_grid(current, "currentIconListView", cols, rows)) touched++;
    } else {
        printf("[SBC] v3: no list-view accessor path\n");
    }

    uint64_t dockListView = try_msg0(mgr, "dockListView");
    if (r_is_objc_ptr(dockListView)) {
        disable_list_autofit(dockListView, "dockListView");
    }

    printf("[SBC] v3: patched home list models=%d\n", touched);
    return touched;
}

static void patch_homescreen_grid(uint64_t iconCtrl, int cols, int rows, bool hideLabels)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    if (!mgr) { printf("[SBC] hs: nil iconManager\n"); return; }
    usleep(50000);

    uint64_t provider = try_msg0(mgr, "listLayoutProvider");
    if (provider) {
        usleep(50000);

        uint64_t loc = r_cfstr("SBIconLocationRoot");
        if (!loc) {
            printf("[SBC] hs: cfstr failed\n");
        } else if (!r_responds(provider, "layoutForIconLocation:")) {
            printf("[SBC] hs: provider lacks layoutForIconLocation:\n");
        } else {
            uint64_t layout = r_msg2(provider, "layoutForIconLocation:", loc, 0, 0, 0);
            if (!layout) {
                printf("[SBC] hs: nil layout for root\n");
            } else {
                usleep(50000);
                uint64_t cfg = try_msg0(layout, "layoutConfiguration");
                if (!cfg) {
                    printf("[SBC] hs: nil layoutConfiguration\n");
                } else if (!r_responds(cfg, "setNumberOfPortraitColumns:")) {
                    printf("[SBC] hs: cfg lacks setNumberOfPortraitColumns:\n");
                } else {
                    usleep(50000);
                    r_msg2(cfg, "setNumberOfPortraitColumns:", (uint64_t)cols, 0, 0, 0);
                    usleep(50000);
                    if (r_responds(cfg, "setNumberOfPortraitRows:"))
                        r_msg2(cfg, "setNumberOfPortraitRows:", (uint64_t)rows, 0, 0, 0);
                    usleep(50000);
                    if (r_responds(cfg, "setNumberOfLandscapeColumns:"))
                        r_msg2(cfg, "setNumberOfLandscapeColumns:", (uint64_t)rows, 0, 0, 0);
                    usleep(50000);
                    if (r_responds(cfg, "setNumberOfLandscapeRows:"))
                        r_msg2(cfg, "setNumberOfLandscapeRows:", (uint64_t)cols, 0, 0, 0);
                    printf("[SBC] hs: provider cols=%d rows=%d\n", cols, rows);

                    if (hideLabels && r_responds(cfg, "setShowsLabels:")) {
                        usleep(50000);
                        r_msg2(cfg, "setShowsLabels:", 0, 0, 0, 0);
                        printf("[SBC] hs: showsLabels=NO\n");
                    }
                }
            }
        }
    } else {
        printf("[SBC] hs: nil listLayoutProvider\n");
    }

    patch_homescreen_list_models_v3(mgr, cols, rows);
}

static bool set_page_icon_capacity(uint64_t listView, int desired, int preferredCols,
                                   const char *tag)
{
    uint64_t model = list_view_model(listView);
    if (!r_is_objc_ptr(model)) return false;

    const char *capacitySetters[] = {
        "setMaximumIconCount:",
        "setMaxIconCount:",
        "setMaximumNumberOfIcons:",
        NULL,
    };
    for (int i = 0; capacitySetters[i]; i++) {
        if (!r_responds(model, capacitySetters[i])) continue;
        r_msg2(model, capacitySetters[i], (uint64_t)desired, 0, 0, 0);
        printf("[SBC:ARRANGE] %s %s -> %d\n", tag, capacitySetters[i], desired);
        return true;
    }

    int bestCols = 0;
    int bestRows = 0;
    int bestDistance = 999;
    for (int cols = 3; cols <= 7; cols++) {
        if (desired % cols != 0) continue;
        int rows = desired / cols;
        if (rows < 4 || rows > 8) continue;
        int distance = cols > preferredCols ? cols - preferredCols : preferredCols - cols;
        if (distance < bestDistance) {
            bestCols = cols;
            bestRows = rows;
            bestDistance = distance;
        }
    }
    if (!bestCols) {
        printf("[SBC:ARRANGE] %s cannot express exact capacity=%d as supported grid\n",
               tag, desired);
        return false;
    }
    return patch_list_model_grid(listView, tag, bestCols, bestRows);
}

static uint64_t icon_array_count(uint64_t model)
{
    uint64_t icons = model_icons_retained(model);
    if (!r_is_objc_ptr(icons)) return UINT64_MAX;
    uint64_t count = r_msg2_main(icons, "count", 0, 0, 0, 0);
    release_remote_object(icons);
    return count;
}

// Do not use CFRetain while redistributing pages. SBIconListModel and its
// icons array can be replaced as a consequence of the preceding grid change.
// Retaining a pointer returned by an earlier RemoteCall is therefore itself
// unsafe: on arm64e CFRetain PAC-crashes when that transient pointer has gone
// stale. Each accessor below is instead completed synchronously on the main
// thread and the result is consumed immediately.
static uint64_t icon_array_count_transient(uint64_t model)
{
    if (!r_is_objc_ptr(model)) return UINT64_MAX;
    uint64_t icons = r_msg2_main(model, "icons", 0, 0, 0, 0);
    if (!r_is_objc_ptr(icons)) return UINT64_MAX;
    return r_msg2_main(icons, "count", 0, 0, 0, 0);
}

static uint64_t page_model_at(uint64_t rootFolder, uint64_t page)
{
    uint64_t listView = r_msg2_main(rootFolder, "iconListViewAtIndex:", page, 0, 0, 0);
    if (!r_is_objc_ptr(listView)) return 0;
    return r_msg2_main(listView, "model", 0, 0, 0, 0);
}

static uint64_t icon_at_index_transient(uint64_t model, uint64_t index)
{
    if (!r_is_objc_ptr(model)) return 0;
    uint64_t icons = r_msg2_main(model, "icons", 0, 0, 0, 0);
    if (!r_is_objc_ptr(icons)) return 0;
    uint64_t count = r_msg2_main(icons, "count", 0, 0, 0, 0);
    if (index >= count) return 0;
    return r_msg2_main(icons, "objectAtIndex:", index, 0, 0, 0);
}

static uint64_t wait_for_page_count(uint64_t rootFolder, uint64_t page,
                                    uint64_t expected)
{
    uint64_t count = UINT64_MAX;
    for (int attempt = 0; attempt < 5; attempt++) {
        count = icon_array_count_transient(page_model_at(rootFolder, page));
        if (count == expected) break;
        usleep(5000);
    }
    return count;
}

static bool move_icon_between_pages(uint64_t rootFolder,
                                    uint64_t sourcePage, uint64_t sourceIndex,
                                    uint64_t destinationPage, uint64_t destinationIndex,
                                    uint64_t sourceCountBefore,
                                    uint64_t destinationCountBefore,
                                    uint64_t icon, const char *tag)
{
    uint64_t sourceModel = page_model_at(rootFolder, sourcePage);
    uint64_t destinationModel = page_model_at(rootFolder, destinationPage);
    if (!r_is_objc_ptr(sourceModel) || !r_is_objc_ptr(destinationModel) ||
        !r_is_objc_ptr(icon)) {
        printf("[SBC:MOVE] %s unsupported page mutation\n", tag);
        return false;
    }
    if (sourceCountBefore == UINT64_MAX || destinationCountBefore == UINT64_MAX ||
        sourceIndex >= sourceCountBefore || destinationIndex > destinationCountBefore) {
        printf("[SBC:MOVE] %s invalid counts source=%llu index=%llu destination=%llu index=%llu\n",
               tag, sourceCountBefore, sourceIndex,
               destinationCountBefore, destinationIndex);
        return false;
    }
    if (!remove_icon_from_model(sourceModel, sourceIndex, icon)) return false;
    uint64_t sourceCountAfter = wait_for_page_count(
        rootFolder, sourcePage, sourceCountBefore - 1);
    if (sourceCountAfter != sourceCountBefore - 1) {
        printf("[SBC:MOVE] %s source count mismatch %llu -> %llu\n",
               tag, sourceCountBefore, sourceCountAfter);
        return false;
    }

    // Removal can rebuild the destination page model as well.
    destinationModel = page_model_at(rootFolder, destinationPage);
    if (insert_icon_into_model(destinationModel, destinationIndex, icon)) {
        uint64_t destinationCountAfter = wait_for_page_count(
            rootFolder, destinationPage, destinationCountBefore + 1);
        if (destinationCountAfter == destinationCountBefore + 1) return true;
        printf("[SBC:MOVE] %s destination count mismatch %llu -> %llu\n",
               tag, destinationCountBefore, destinationCountAfter);
    }

    printf("[SBC:MOVE] %s insertion failed; restoring source page\n", tag);
    sourceModel = page_model_at(rootFolder, sourcePage);
    insert_icon_into_model(sourceModel, sourceIndex, icon);
    return false;
}

static int rebalance_page_models(uint64_t rootFolder, uint64_t count,
                                 int firstPageIcons, int otherPageIcons)
{
    int moved = 0;
    bool failed = false;
    for (uint64_t page = 0; page + 1 < count; page++) {
        uint64_t model = page_model_at(rootFolder, page);
        if (!r_is_objc_ptr(model)) continue;
        uint64_t desired = (uint64_t)(page == 0 ? firstPageIcons : otherPageIcons);
        uint64_t current = icon_array_count_transient(model);
        if (current == UINT64_MAX) {
            printf("[SBC:ARRANGE] page[%llu] icon array unavailable\n", page);
            failed = true;
            continue;
        }
        uint64_t before = current;

        // Push overflow forward. Taking the last icon and inserting it at
        // index zero preserves the original order of the overflow block.
        while (current > desired) {
            model = page_model_at(rootFolder, page);
            uint64_t iconIndex = current - 1;
            uint64_t icon = icon_at_index_transient(model, iconIndex);
            uint64_t destinationCount = icon_array_count_transient(
                page_model_at(rootFolder, page + 1));
            bool didMove = r_is_objc_ptr(icon) &&
                move_icon_between_pages(rootFolder, page, iconIndex,
                                        page + 1, 0, current, destinationCount,
                                        icon, "page overflow");
            if (!didMove) {
                return -1;
            }
            moved++;
            current--;
        }

        // Fill a short page from the first non-empty later page. This also
        // closes gaps when SpringBoard has left an empty intermediate page.
        while (current < desired) {
            uint64_t donorPage = page + 1;
            uint64_t donorCount = UINT64_MAX;
            while (donorPage < count) {
                uint64_t donorModel = page_model_at(rootFolder, donorPage);
                donorCount = icon_array_count_transient(donorModel);
                if (donorCount != UINT64_MAX && donorCount > 0) break;
                donorPage++;
            }
            if (donorPage >= count) break;
            model = page_model_at(rootFolder, page);
            uint64_t donorModel = page_model_at(rootFolder, donorPage);
            uint64_t icon = icon_at_index_transient(donorModel, 0);
            bool didMove = r_is_objc_ptr(icon) &&
                move_icon_between_pages(rootFolder, donorPage, 0,
                                        page, current, donorCount, current,
                                        icon, "page fill");
            if (!didMove) {
                return -1;
            }
            moved++;
            current++;
        }
        printf("[SBC:ARRANGE] page[%llu] icons %llu -> %llu target=%llu\n",
               page, before, current == UINT64_MAX ? 0 : current, desired);
    }
    return failed ? -1 : moved;
}

static bool arrange_homescreen_pages(uint64_t iconCtrl, int preferredCols,
                                     int firstPageIcons, int otherPageIcons)
{
    uint64_t mgr = try_msg0(iconCtrl, "iconManager");
    uint64_t rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder) ||
        !r_responds(rootFolder, "iconListViewCount") ||
        !r_responds(rootFolder, "iconListViewAtIndex:")) {
        printf("[SBC:ARRANGE] page list accessors unavailable\n");
        return false;
    }

    uint64_t count = r_msg2(rootFolder, "iconListViewCount", 0, 0, 0, 0);
    uint64_t limit = count < 64 ? count : 64;
    int changed = 0;
    for (uint64_t i = 0; i < limit; i++) {
        uint64_t listView = r_msg2(rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(listView)) continue;
        char tag[32];
        snprintf(tag, sizeof(tag), "page[%llu]", i);
        int desired = i == 0 ? firstPageIcons : otherPageIcons;
        if (set_page_icon_capacity(listView, desired, preferredCols, tag)) changed++;
    }

    // Grid changes can rebuild SBIconListView and its model. Never reuse the
    // raw pointers captured before setGridSize:/setNeedsLayout.
    usleep(100000);
    mgr = try_msg0(iconCtrl, "iconManager");
    rootFolder = try_msg0(mgr, "rootFolderController");
    if (!r_is_objc_ptr(rootFolder)) {
        printf("[SBC:ARRANGE] root folder disappeared after capacity update\n");
        return false;
    }
    count = r_msg2_main(rootFolder, "iconListViewCount", 0, 0, 0, 0);
    limit = count < 64 ? count : 64;
    int moved = rebalance_page_models(rootFolder, limit,
                                      firstPageIcons, otherPageIcons);

    // Trigger visual refresh only after all reads and mutations are finished.
    // Running this inside the capacity loop can asynchronously replace the
    // page models and icon arrays while the arranger is still using them.
    mgr = try_msg0(iconCtrl, "iconManager");
    rootFolder = try_msg0(mgr, "rootFolderController");
    if (r_is_objc_ptr(rootFolder)) {
        uint64_t refreshedCount = r_msg2_main(
            rootFolder, "iconListViewCount", 0, 0, 0, 0);
        uint64_t refreshedLimit = refreshedCount < 64 ? refreshedCount : 64;
        for (uint64_t i = 0; i < refreshedLimit; i++) {
            uint64_t listView = r_msg2_main(
                rootFolder, "iconListViewAtIndex:", i, 0, 0, 0);
            if (r_is_objc_ptr(listView) &&
                r_responds_main(listView, "setNeedsLayout")) {
                r_msg2_main_async(listView, "setNeedsLayout", 0, 0, 0, 0);
            }
        }
    }
    printf("[SBC:ARRANGE] pages=%llu capacities=%d moved=%d first=%d others=%d\n",
           limit, changed, moved, firstPageIcons, otherPageIcons);
    return changed > 0 && moved >= 0;
}

bool sbcustomizer_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                                   bool arrangePages, int firstPageIcons, int otherPageIcons,
                                   bool autoDockApp, const char *dockAppBundleID)
{
    // The shared Objective-C helper normally leaves 50 ms after every
    // message. Page redistribution can issue hundreds of synchronous
    // main-thread messages, turning that safety delay into a long pause.
    // These calls already wait for main-thread completion. Avoid adding a
    // settle delay to every selector lookup and message in a redistribution;
    // mutation verification below provides the required synchronization.
    uint32_t oldSettleUS = r_settle_us(0);
    dockIcons = clamp(dockIcons, 4, 7);
    hsCols    = clamp(hsCols,    3, 7);
    hsRows    = clamp(hsRows,    4, 8);
    firstPageIcons = clamp(firstPageIcons, 12, 49);
    otherPageIcons = clamp(otherPageIcons, 12, 49);
    printf("[SBC] === entry === dock=%d hs=%dx%d hideLabels=%d arrange=%d first=%d others=%d autoDock=%d bundle=%s\n",
           dockIcons, hsCols, hsRows, hideLabels,
           arrangePages, firstPageIcons, otherPageIcons, autoDockApp,
           dockAppBundleID ?: "");

    bool ok = false;
    do {
        usleep(100000);
        uint64_t cls = r_class("SBIconController");
        if (!cls) { printf("[SBC] SBIconController missing\n"); break; }
        usleep(50000);

        uint64_t iconCtrl = r_msg2(cls, "sharedInstance", 0, 0, 0, 0);
        if (!iconCtrl) { printf("[SBC] +sharedInstance nil\n"); break; }
        printf("[SBC] iconCtrl=0x%llx\n", iconCtrl);

        patch_dock(iconCtrl, dockIcons);
        bool dockAppOK = true;
        if (autoDockApp && dockIcons > 4) {
            dockAppOK = auto_add_app_to_dock(iconCtrl, dockIcons, dockAppBundleID);
        } else if (autoDockApp) {
            printf("[SBC:DOCKAPP] deferred until Dock capacity is above four\n");
        }
        patch_homescreen_grid(iconCtrl, hsCols, hsRows, hideLabels);
        bool arrangeOK = true;
        if (arrangePages) {
            arrangeOK = arrange_homescreen_pages(
                iconCtrl, hsCols, firstPageIcons, otherPageIcons);
        }
        ok = arrangeOK && dockAppOK;
    } while (0);

    r_settle_us(oldSettleUS);
    return ok;
}

bool sbcustomizer_apply(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                        bool arrangePages, int firstPageIcons, int otherPageIcons,
                        bool autoDockApp, const char *dockAppBundleID)
{
    if (init_remote_call("SpringBoard", false) != 0) {
        printf("[SBC] init_remote_call(SpringBoard) failed\n");
        return false;
    }

    bool ok = sbcustomizer_apply_in_session(dockIcons, hsCols, hsRows, hideLabels,
                                            arrangePages, firstPageIcons, otherPageIcons,
                                            autoDockApp, dockAppBundleID);
    destroy_remote_call();
    return ok;
}