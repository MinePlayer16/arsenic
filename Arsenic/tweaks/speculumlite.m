//
//  speculumlite.m
//  RemoteCall-only Lockscreen tweaking
//

#import "speculumlite.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <CoreText/CoreText.h>
#import <mach/mach.h>
#include <stdio.h>

static uint64_t gSpecContainerView = 0;
static uint64_t gSpecTimeView = 0;
static uint64_t gSpecDateView = 0;

static uint64_t gSpecLabels[kSpeculumMaxWidgets] = {0};
static char gLastStrings[kSpeculumMaxWidgets][256] = {0};
static char gLastFontPaths[kSpeculumMaxWidgets][512] = {0};

static int gTickCount = 0;
static NSTimer *gSpecLiveTimer = nil;
static SpeculumLiteConfig gCurrentConfig;

static bool gSpecIsFullyInitialized = false;
static SpeculumLiteConfig gLastAppliedConfig;

// ==========================================
// App-Side Native String Formatter
// ==========================================
static NSString *spec_format_text(NSString *template) {
    if (template.length == 0) return @"";
    
    NSMutableString *result = [template mutableCopy];
    UIDevice *device = [UIDevice currentDevice];
    
    // ---------------------------------------------------------
    // 1. SYSTEM & HARDWARE PATTERN TAGS
    // ---------------------------------------------------------
    
    // {battery}
    if ([result containsString:@"{battery}"]) {
        device.batteryMonitoringEnabled = YES;
        int bat = (int)(device.batteryLevel * 100.0f);
        [result replaceOccurrencesOfString:@"{battery}"
                                withString:[NSString stringWithFormat:@"%d", bat]
                                   options:0 range:NSMakeRange(0, result.length)];
    }
    
    // {battery_status}
    if ([result containsString:@"{battery_status}"]) {
        device.batteryMonitoringEnabled = YES;
        NSString *status = @"Unplugged";
        if (device.batteryState == UIDeviceBatteryStateCharging) status = @"Charging";
        else if (device.batteryState == UIDeviceBatteryStateFull) status = @"Full";
        
        [result replaceOccurrencesOfString:@"{battery_status}"
                                withString:status
                                   options:0 range:NSMakeRange(0, result.length)];
    }
    
    // {device_name}
    if ([result containsString:@"{device_name}"]) {
        [result replaceOccurrencesOfString:@"{device_name}"
                                withString:device.name
                                   options:0 range:NSMakeRange(0, result.length)];
    }
    
    // {storage_free}
    if ([result containsString:@"{storage_free}"]) {
        NSDictionary *attrs = [[NSFileManager defaultManager] attributesOfFileSystemForPath:NSHomeDirectory() error:nil];
        if (attrs) {
            int64_t freeBytes = [attrs[NSFileSystemFreeSize] longLongValue];
            double freeGB = freeBytes / (1024.0 * 1024.0 * 1024.0);
            [result replaceOccurrencesOfString:@"{storage_free}"
                                    withString:[NSString stringWithFormat:@"%.1f GB", freeGB]
                                       options:0 range:NSMakeRange(0, result.length)];
        }
    }
    
    // {uptime}
    if ([result containsString:@"{uptime}"]) {
        NSTimeInterval uptime = [[NSProcessInfo processInfo] systemUptime];
        int days = (int)(uptime / 86400);
        int hours = (int)((uptime - (days * 86400)) / 3600);
        int minutes = (int)((uptime - (days * 86400) - (hours * 3600)) / 60);
        
        NSMutableString *upStr = [NSMutableString string];
        if (days > 0) [upStr appendFormat:@"%dd ", days];
        if (hours > 0 || days > 0) [upStr appendFormat:@"%dh ", hours];
        [upStr appendFormat:@"%dm", minutes];
        
        [result replaceOccurrencesOfString:@"{uptime}"
                                withString:upStr
                                   options:0 range:NSMakeRange(0, result.length)];
    }
    
    // {ram_free}
    if ([result containsString:@"{ram_free}"]) {
        mach_port_t host_port = mach_host_self();
        mach_msg_type_number_t host_size = sizeof(vm_statistics_data_t) / sizeof(integer_t);
        vm_size_t pagesize;
        vm_statistics_data_t vm_stat;
        
        host_page_size(host_port, &pagesize);
        if (host_statistics(host_port, HOST_VM_INFO, (host_info_t)&vm_stat, &host_size) == KERN_SUCCESS) {
            double freeMem = ((vm_stat.free_count + vm_stat.inactive_count) * pagesize) / (1024.0 * 1024.0);
            [result replaceOccurrencesOfString:@"{ram_free}"
                                    withString:[NSString stringWithFormat:@"%.0f MB", freeMem]
                                       options:0 range:NSMakeRange(0, result.length)];
        }
    }
    
    // ---------------------------------------------------------
    // 2. CACHED PATTERN TAGS (Weather & Media)
    // ---------------------------------------------------------
    
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    
    if ([result containsString:@"{temp}"]) {
        NSString *temp = [defaults stringForKey:@"SpeculumLiteWeatherTemp"] ?: @"--";
        [result replaceOccurrencesOfString:@"{temp}" withString:temp options:0 range:NSMakeRange(0, result.length)];
    }
    
    if ([result containsString:@"{weather}"]) {
        NSString *cond = [defaults stringForKey:@"SpeculumLiteWeatherCond"] ?: @"Unknown";
        [result replaceOccurrencesOfString:@"{weather}" withString:cond options:0 range:NSMakeRange(0, result.length)];
    }
    
    if ([result containsString:@"{song}"]) {
        NSString *song = [defaults stringForKey:@"SpeculumLiteMediaSong"] ?: @"Not Playing";
        [result replaceOccurrencesOfString:@"{song}" withString:song options:0 range:NSMakeRange(0, result.length)];
    }

    if ([result containsString:@"{weather_icon}"]) {
        NSString *icon = [defaults stringForKey:@"SpeculumLiteWeatherIcon"] ?: @"--";
        [result replaceOccurrencesOfString:@"{weather_icon}" withString:icon options:0 range:NSMakeRange(0, result.length)];
    }

    // ---------------------------------------------------------
    // 3. DATE & TIME (Fallback for remaining pattern tags)
    // ---------------------------------------------------------
    
    NSError *error = nil;
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:@"\\{(.*?)\\}" options:0 error:&error];
    
    NSArray *matches = [regex matchesInString:result options:0 range:NSMakeRange(0, result.length)];
    NSDate *now = [NSDate date];
    
    for (NSTextCheckingResult *match in [matches reverseObjectEnumerator]) {
        NSRange fullRange = match.range;
        NSRange innerRange = [match rangeAtIndex:1];
        NSString *format = [result substringWithRange:innerRange];
        
        NSDateFormatter *df = [[NSDateFormatter alloc] init];
        df.dateFormat = format;
        NSString *dateStr = [df stringFromDate:now];
        
        [result replaceCharactersInRange:fullRange withString:dateStr ?: @""];
    }
    
    return result;
}

static NSString* spec_extract_postscript_name(NSString *fontPath) {
    CGDataProviderRef provider = CGDataProviderCreateWithFilename(fontPath.UTF8String);
    if (!provider) return nil;
    CGFontRef font = CGFontCreateWithDataProvider(provider);
    CGDataProviderRelease(provider);
    if (!font) return nil;
    NSString *name = (__bridge_transfer NSString *)CGFontCopyPostScriptName(font);
    CGFontRelease(font);
    return name;
}

static void spec_hex_to_rgb(NSString *hex, double *r, double *g, double *b) {
    hex = [hex stringByReplacingOccurrencesOfString:@"#" withString:@""];
    unsigned int rgb = 0;
    [[NSScanner scannerWithString:hex] scanHexInt:&rgb];
    *r = ((rgb >> 16) & 0xFF) / 255.0;
    *g = ((rgb >> 8) & 0xFF) / 255.0;
    *b = (rgb & 0xFF) / 255.0;
}

// ==========================================
// IPC View Traversal
// ==========================================
static bool spec_is_kind_of_class(uint64_t obj, uint64_t cls) {
    if (!obj || !cls) return false;
    return (r_msg2_main(obj, "isKindOfClass:", cls, 0, 0, 0) & 0xFF) != 0;
}

static void spec_scan_views_shallow(uint64_t view, int depth) {
    if (!r_is_objc_ptr(view) || depth > 5) return;
    if (gSpecTimeView && gSpecDateView) return;
    
    uint64_t timeCls = r_class("CSProminentTimeView");
    uint64_t dateCls = r_class("CSProminentSubtitleDateView");
    
    if (!gSpecTimeView && spec_is_kind_of_class(view, timeCls)) gSpecTimeView = view;
    if (!gSpecDateView && spec_is_kind_of_class(view, dateCls)) gSpecDateView = view;
    
    if (r_responds_main(view, "subviews")) {
        uint64_t subviews = r_msg2_main(view, "subviews", 0, 0, 0, 0);
        if (r_is_objc_ptr(subviews)) {
            uint64_t count = r_msg2_main(subviews, "count", 0, 0, 0, 0);
            for (uint64_t i = 0; i < count; i++) {
                spec_scan_views_shallow(r_msg2_main(subviews, "objectAtIndex:", i, 0, 0, 0), depth + 1);
                if (gSpecTimeView && gSpecDateView) return;
            }
        }
    }
}

static void spec_find_clock_vc(uint64_t vc, int depth) {
    if (!r_is_objc_ptr(vc) || depth > 12 || gSpecContainerView) return;
    
    uint64_t prominentCls = r_class("CSProminentDisplayViewController");
    uint64_t legacyCls = r_class("SBFLockScreenDateViewController");
    
    if (spec_is_kind_of_class(vc, prominentCls) || spec_is_kind_of_class(vc, legacyCls)) {
        gSpecContainerView = r_msg2_main(vc, "view", 0, 0, 0, 0);
        return;
    }
    
    uint64_t children = r_msg2_main(vc, "childViewControllers", 0, 0, 0, 0);
    if (r_is_objc_ptr(children)) {
        uint64_t count = r_msg2_main(children, "count", 0, 0, 0, 0);
        for (uint64_t i = 0; i < count; i++) {
            spec_find_clock_vc(r_msg2_main(children, "objectAtIndex:", i, 0, 0, 0), depth + 1);
        }
    }
}

static void spec_clear_target_cache(void) {
    gSpecContainerView = 0;
    gSpecTimeView = 0;
    gSpecDateView = 0;
}

static bool spec_locate_targets(void) {
    if (gSpecContainerView && gSpecTimeView) return true;
    spec_clear_target_cache();
    
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    uint64_t winCount = r_msg2_main(windows, "count", 0, 0, 0, 0);
    
    uint64_t targetWin = 0;
    uint64_t csCls = r_class("SBCoverSheetWindow");
    
    for (uint64_t i = 0; i < winCount && i < 16; i++) {
        uint64_t w = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (spec_is_kind_of_class(w, csCls)) {
            targetWin = w;
            break;
        }
    }
    
    if (!targetWin) return false;
    
    spec_find_clock_vc(r_msg2_main(targetWin, "rootViewController", 0, 0, 0, 0), 0);
    if (gSpecContainerView) spec_scan_views_shallow(gSpecContainerView, 0);

    if (!gSpecContainerView || !gSpecTimeView) {
        spec_clear_target_cache();
        return false;
    }
    
    return true;
}

// ==========================================
// Timer
// ==========================================
static void speculumlite_native_tick(NSTimer *timer) {
    //stops the timer to save battery
    if (!spec_locate_targets()) {
        [gSpecLiveTimer invalidate];
        gSpecLiveTimer = nil;
        return;
    }
    speculumlite_apply_in_session(gCurrentConfig);
}



// ==========================================
// Tweak Engine Core
// ==========================================
bool speculumlite_apply_in_session(SpeculumLiteConfig config) {
    if (!config.enabled) return speculumlite_stop_in_session();

    gTickCount++;
    if (!spec_locate_targets()) return false;
    bool configChanged = memcmp(&config, &gLastAppliedConfig, sizeof(SpeculumLiteConfig)) != 0;
    if (configChanged || !gSpecIsFullyInitialized) {
        
        // ghost cleanup
        uint64_t containerSubviews = r_msg2_main(gSpecContainerView, "subviews", 0, 0, 0, 0);
        if (r_is_objc_ptr(containerSubviews)) {
            uint64_t subCount = r_msg2_main(containerSubviews, "count", 0, 0, 0, 0);
            for (uint64_t i = 0; i < subCount; i++) {
                uint64_t sub = r_msg2_main(containerSubviews, "objectAtIndex:", i, 0, 0, 0);
                uint64_t tag = r_msg2_main(sub, "tag", 0, 0, 0, 0);
                if (tag == 893475) {
                    bool isOurs = false;
                    for (int w = 0; w < kSpeculumMaxWidgets; w++) {
                        if (gSpecLabels[w] == sub) { isOurs = true; break; }
                    }
                    if (!isOurs) r_msg2_main(sub, "removeFromSuperview", 0, 0, 0, 0);
                }
            }
        }

        // hide native elements (if toggled from settings)
        if (config.hideDate && gSpecDateView) {
            r_msg2_main(gSpecDateView, "setHidden:", 1, 0, 0, 0);
        }
        if (config.hideTime && gSpecTimeView) {
            uint64_t timeSubviews = r_msg2_main(gSpecTimeView, "subviews", 0, 0, 0, 0);
            uint64_t count = r_msg2_main(timeSubviews, "count", 0, 0, 0, 0);
            for (uint64_t i = 0; i < count; i++) {
                uint64_t sub = r_msg2_main(timeSubviews, "objectAtIndex:", i, 0, 0, 0);
                bool isOurs = false;
                for (int w = 0; w < config.widgetCount; w++) {
                    if (sub == gSpecLabels[w]) { isOurs = true; break; }
                }
                if (!isOurs) r_msg2_main(sub, "setHidden:", 1, 0, 0, 0);
            }
        }
        
        gLastAppliedConfig = config;
        gSpecIsFullyInitialized = true;
    }

    const double screenWidth = [UIScreen mainScreen].bounds.size.width;
    const double screenHeight = [UIScreen mainScreen].bounds.size.height;
    const double screenScale = [UIScreen mainScreen].scale;
    const double baseFontSize = 20.0;

    for (int i = 0; i < config.widgetCount && i < kSpeculumMaxWidgets; i++) {
        SpeculumWidget widget = config.widgets[i];
        bool created = false;

        // init
        if (!gSpecLabels[i]) {
            uint64_t label = r_msg2_main(r_msg2_main(r_class("UILabel"), "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);
            if (!r_is_objc_ptr(label)) continue;
            
            r_msg2_main(label, "setTextAlignment:", 1, 0, 0, 0);
            r_msg2_main(label, "setTag:", 893475, 0, 0, 0);
            r_msg2_main(gSpecContainerView, "addSubview:", label, 0, 0, 0);
            gSpecLabels[i] = label;
            created = true;
        }

        uint64_t label = gSpecLabels[i];

        if (configChanged || created) {
            // font
            NSString *fontPath = [NSString stringWithUTF8String:widget.fontPath];
            uint64_t font = 0;
            if (fontPath.length > 0) {
                uint64_t nsPath = r_nsstr_retained(widget.fontPath);
                uint64_t url = r_msg2_main(r_class("NSURL"), "fileURLWithPath:", nsPath, 0, 0, 0);
                r_msg2_main(nsPath, "release", 0, 0, 0, 0);
                if (r_is_objc_ptr(url)) {
                    r_dlsym_call(R_TIMEOUT, "CTFontManagerRegisterFontsForURL", url, 1, 0, 0, 0, 0, 0, 0);
                }
                NSString *psName = spec_extract_postscript_name(fontPath);
                if (psName.length > 0) {
                    uint64_t nsFontName = r_nsstr_retained(psName.UTF8String);
                    font = r_msg2_main_raw(r_class("UIFont"), "fontWithName:size:", &nsFontName, sizeof(nsFontName), &baseFontSize, sizeof(baseFontSize), NULL, 0, NULL, 0);
                    r_msg2_main(nsFontName, "release", 0, 0, 0, 0);
                }
            }
            if (!r_is_objc_ptr(font)) {
                font = r_msg2_main_raw(r_class("UIFont"), "boldSystemFontOfSize:", &baseFontSize, sizeof(baseFontSize), NULL, 0, NULL, 0, NULL, 0);
            }
            if (r_is_objc_ptr(font)) r_msg2_main(label, "setFont:", font, 0, 0, 0);

            // color
            NSString *hexColor = [NSString stringWithUTF8String:widget.hexColor];
            double red = 1.0, green = 1.0, blue = 1.0, alpha = 1.0;
            if (hexColor.length > 0) spec_hex_to_rgb(hexColor, &red, &green, &blue);
            uint64_t color = r_msg2_main_raw(r_class("UIColor"), "colorWithRed:green:blue:alpha:", &red, sizeof(red), &green, sizeof(green), &blue, sizeof(blue), &alpha, sizeof(alpha));
            if (r_is_objc_ptr(color)) r_msg2_main(label, "setTextColor:", color, 0, 0, 0);

            // transform and scale
            double widgetScale = widget.scaleSize > 0.0 ? widget.scaleSize : 1.0;
            double transform[6] = { widgetScale, 0.0, 0.0, widgetScale, 0.0, 0.0 };
            r_msg2_main_raw(label, "setTransform:", transform, sizeof(transform), NULL, 0, NULL, 0, NULL, 0);

            double renderScale = screenScale * (widgetScale > 1.0 ? widgetScale : 1.0);
            uint64_t layer = r_msg2_main(label, "layer", 0, 0, 0, 0);
            r_msg2_main_raw(layer, "setContentsScale:", &renderScale, sizeof(renderScale), NULL, 0, NULL, 0, NULL, 0);
        }

        // fast path for wake/unlock
        NSString *template = [NSString stringWithUTF8String:widget.textTemplate];
        NSString *displayString = spec_format_text(template);
        const char *displayUTF8 = displayString.UTF8String ?: "";

        bool textChanged = strcmp(displayUTF8, gLastStrings[i]) != 0;
        
        if (textChanged || created || configChanged) {
            uint64_t nsText = r_nsstr_retained(displayUTF8);
            r_msg2_main(label, "setText:", nsText, 0, 0, 0);
            r_msg2_main(nsText, "release", 0, 0, 0, 0);
            snprintf(gLastStrings[i], sizeof(gLastStrings[i]), "%s", displayUTF8);

            r_msg2_main(label, "sizeToFit", 0, 0, 0, 0);

            struct { double x, y; } center = {
                screenWidth * widget.posX,
                screenHeight * widget.posY
            };
            r_msg2_main_raw(label, "setCenter:", &center, sizeof(center), NULL, 0, NULL, 0, NULL, 0);
        }
    }
    if (configChanged || !gSpecIsFullyInitialized) {
        for (int i = config.widgetCount; i < kSpeculumMaxWidgets; i++) {
            if (gSpecLabels[i]) {
                r_msg2_main(gSpecLabels[i], "removeFromSuperview", 0, 0, 0, 0);
                gSpecLabels[i] = 0;
            }
            gLastStrings[i][0] = '\0';
            gLastFontPaths[i][0] = '\0';
        }
    }

    return true;
}

bool speculumlite_stop_in_session(void) {
    gSpecIsFullyInitialized = false;
    memset(&gLastAppliedConfig, 0, sizeof(gLastAppliedConfig));
    if (gSpecLiveTimer) {
        [gSpecLiveTimer invalidate];
        gSpecLiveTimer = nil;
    }
    uint32_t oldSettle = r_settle_us(1000);
    
    if (gSpecDateView) r_msg2_main(gSpecDateView, "setHidden:", 0, 0, 0, 0);
    
    if (gSpecTimeView) {
        uint64_t timeSubviews = r_msg2_main(gSpecTimeView, "subviews", 0, 0, 0, 0);
        uint64_t count = r_msg2_main(timeSubviews, "count", 0, 0, 0, 0);
        for (uint64_t i = 0; i < count; i++) {
            uint64_t sub = r_msg2_main(timeSubviews, "objectAtIndex:", i, 0, 0, 0);
            
            bool isOurs = false;
            for (int w = 0; w < kSpeculumMaxWidgets; w++) {
                if (sub == gSpecLabels[w]) isOurs = true;
            }
            if (!isOurs) r_msg2_main(sub, "setHidden:", 0, 0, 0, 0);
        }
    }
    
    for (int i = 0; i < kSpeculumMaxWidgets; i++) {
        if (gSpecLabels[i]) {
            r_msg2_main(gSpecLabels[i], "setHidden:", 1, 0, 0, 0);
            r_msg2_main(gSpecLabels[i], "removeFromSuperview", 0, 0, 0, 0);
            gSpecLabels[i] = 0;
        }
        gLastStrings[i][0] = '\0';
        gLastFontPaths[i][0] = '\0';
    }

    spec_clear_target_cache();
    
    r_settle_us(oldSettle);
    return true;
}

void speculumlite_forget_remote_state(void) {
    gSpecIsFullyInitialized = false;
    memset(&gLastAppliedConfig, 0, sizeof(gLastAppliedConfig));
    gSpecContainerView = 0;
    gSpecTimeView = 0;
    gSpecDateView = 0;
    
    for (int i = 0; i < kSpeculumMaxWidgets; i++) {
        gSpecLabels[i] = 0;
        gLastStrings[i][0] = '\0';
        gLastFontPaths[i][0] = '\0';
    }
    
    gTickCount = 0;
}
