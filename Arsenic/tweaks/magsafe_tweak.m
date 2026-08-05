#import "magsafe_tweak.h"
#import "remote_objc.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"
#import <stdint.h>
#import <unistd.h>
#import <stdio.h>

static const uint64_t kMagsafeTag = 0xBA77E81;
static uint64_t gMagsafeView = 0;
static uint64_t gMagsafeWindow = 0;
static uint64_t gMagsafeShapeLayer = 0;
static uint64_t gMagsafeTextLayer = 0;
static uint64_t gMagsafeBoltView = 0;

static uint64_t gGreenColor = 0;
static uint64_t gRedColor = 0;
static uint64_t gPercentStrings[101] = {0};

static uint64_t gGreenCGColor = 0;
static uint64_t gRedCGColor = 0;
static uint64_t gCATransactionClass = 0;

static uint64_t gFontName = 0;
static uint64_t gAlignMode = 0;
static uint64_t gLineCap = 0;

static uint64_t magsafe_target_window(void) {
    uint64_t UIApplication = r_class("UIApplication");
    uint64_t app = r_msg2_main(UIApplication, "sharedApplication", 0, 0, 0, 0);
    if (!r_is_objc_ptr(app)) return 0;
    
    uint64_t windows = r_msg2_main(app, "windows", 0, 0, 0, 0);
    uint64_t count = r_msg2_main(windows, "count", 0, 0, 0, 0);
    
    uint64_t coverSheetCls = r_class("SBCoverSheetWindow"); 
    uint64_t homeScreenCls = r_class("SBHomeScreenWindow"); 
    
    uint64_t bestWindow = 0;
    for (uint64_t i = 0; i < count && i < 20; i++) {
        uint64_t window = r_msg2_main(windows, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(window)) continue;
        if (r_is_objc_ptr(coverSheetCls) && r_msg2_main(window, "isKindOfClass:", coverSheetCls, 0, 0, 0)) return window;
        if (r_is_objc_ptr(homeScreenCls) && r_msg2_main(window, "isKindOfClass:", homeScreenCls, 0, 0, 0)) bestWindow = window;
    }
    
    if (bestWindow) return bestWindow;
    uint64_t keyWindow = r_msg2_main(app, "keyWindow", 0, 0, 0, 0);
    return r_is_objc_ptr(keyWindow) ? keyWindow : 0;
}

bool magsafe_tweak_init_in_session(int style) {
    if (gMagsafeView) return true;
    uint64_t targetWindow = magsafe_target_window();
    if (!r_is_objc_ptr(targetWindow)) return false;
    gMagsafeWindow = targetWindow;

    uint64_t UIColor = r_class("UIColor");
    gGreenColor = r_msg2_main(UIColor, "systemGreenColor", 0, 0, 0, 0);
    r_msg2_main(gGreenColor, "retain", 0, 0, 0, 0);
    gGreenCGColor = r_msg2_main(gGreenColor, "CGColor", 0, 0, 0, 0);

    gRedColor = r_msg2_main(UIColor, "systemRedColor", 0, 0, 0, 0);
    r_msg2_main(gRedColor, "retain", 0, 0, 0, 0);
    gRedCGColor = r_msg2_main(gRedColor, "CGColor", 0, 0, 0, 0);

    gCATransactionClass = r_class("CATransaction"); 

    // ignore Style parameter (WIP)
    for (int i = 0; i <= 100; i++) {
        char buf[32];
        snprintf(buf, sizeof(buf), "%d%% Charged", i);
        gPercentStrings[i] = r_nsstr_retained(buf); 
    }
    
    gFontName = r_nsstr_retained("HelveticaNeue");
    gAlignMode = r_nsstr_retained("center");
    gLineCap = r_nsstr_retained("round");

    double viewSize = 300.0;
    double viewY = 270.0;
    double viewX = (390.0 - viewSize) / 2.0; 
    
    double lineWidth = 24.0;
    double shapeSize = viewSize - lineWidth;
    double shapeOffset = lineWidth / 2.0;

    // --- VIEW ---
    uint64_t UIView = r_class("UIView");
    uint64_t view = r_msg2_main(r_msg2_main(UIView, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);
    struct { double x, y, w, h; } frame = { viewX, viewY, viewSize, viewSize };
    r_msg2_main_raw(view, "setFrame:", &frame, sizeof(frame), NULL, 0, NULL, 0, NULL, 0);
    
    uint64_t clearColor = r_msg2_main(UIColor, "clearColor", 0, 0, 0, 0);
    uint64_t viewLayer = r_msg2_main(view, "layer", 0, 0, 0, 0);
    
    r_msg2_main(view, "setBackgroundColor:", clearColor, 0, 0, 0);
    
    uint64_t UIBlurEffect = r_class("UIBlurEffect");
    uint64_t blurEffect = r_msg2_main(UIBlurEffect, "effectWithStyle:", 2, 0, 0, 0); 
    uint64_t UIVisualEffectView = r_class("UIVisualEffectView");
    uint64_t blurView = r_msg2_main(r_msg2_main(UIVisualEffectView, "alloc", 0, 0, 0, 0), "initWithEffect:", blurEffect, 0, 0, 0);
    
    struct { double x, y, w, h; } blurFrame = { -1000.0, -1000.0, 3000.0, 3000.0 };
    r_msg2_main_raw(blurView, "setFrame:", &blurFrame, sizeof(blurFrame), NULL, 0, NULL, 0, NULL, 0);
    
    r_msg2_main(view, "addSubview:", blurView, 0, 0, 0);
    r_msg2_main(blurView, "release", 0, 0, 0, 0);
    
    r_msg2_main(view, "setTag:", kMagsafeTag, 0, 0, 0);

    // --- SHAPELAYER ---
    uint64_t CAShapeLayer = r_class("CAShapeLayer");
    uint64_t UIBezierPath = r_class("UIBezierPath");
    struct { double x, y, w, h; } pathRect = { shapeOffset, shapeOffset, shapeSize, shapeSize };
    uint64_t path = r_msg2_main_raw(UIBezierPath, "bezierPathWithOvalInRect:", &pathRect, sizeof(pathRect), NULL, 0, NULL, 0, NULL, 0);
    uint64_t cgPath = r_msg2_main(path, "CGPath", 0, 0, 0, 0);
    
    // --- RING VIEW ---
    uint64_t ringView = r_msg2_main(r_msg2_main(UIView, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);
    struct { double x, y, w, h; } ringFrame = { 0.0, 0.0, viewSize, viewSize };
    r_msg2_main_raw(ringView, "setFrame:", &ringFrame, sizeof(ringFrame), NULL, 0, NULL, 0, NULL, 0);
    
    struct { double a, b, c, d, tx, ty; } transform = { 0.0, -1.0, 1.0, 0.0, 0.0, 0.0 };
    r_msg2_main_raw(ringView, "setTransform:", &transform, sizeof(transform), NULL, 0, NULL, 0, NULL, 0);
    
    r_msg2_main(view, "addSubview:", ringView, 0, 0, 0);
    uint64_t ringLayer = r_msg2_main(ringView, "layer", 0, 0, 0, 0);
    r_msg2_main(ringView, "release", 0, 0, 0, 0);

    // GREY RING
    uint64_t trackLayer = r_msg2_main(r_msg2_main(CAShapeLayer, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);
    r_msg2_main(trackLayer, "setPath:", cgPath, 0, 0, 0);
    r_msg2_main(trackLayer, "setFillColor:", r_msg2_main(clearColor, "CGColor", 0, 0, 0, 0), 0, 0, 0);
    r_msg2_main_raw(trackLayer, "setLineWidth:", &lineWidth, sizeof(lineWidth), NULL, 0, NULL, 0, NULL, 0);

    uint64_t UIColorClass = r_class("UIColor");
    uint64_t grayColor = r_msg2_main(UIColorClass, "systemGray4Color", 0, 0, 0, 0); 
    r_msg2_main(trackLayer, "setStrokeColor:", r_msg2_main(grayColor, "CGColor", 0, 0, 0, 0), 0, 0, 0);
    r_msg2_main(ringLayer, "addSublayer:", trackLayer, 0, 0, 0);
    r_msg2_main(trackLayer, "release", 0, 0, 0, 0);
    
    // COLORED RING
    uint64_t shapeLayer = r_msg2_main(r_msg2_main(CAShapeLayer, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);
    r_msg2_main(shapeLayer, "setPath:", cgPath, 0, 0, 0);

    r_msg2_main(shapeLayer, "setFillColor:", r_msg2_main(clearColor, "CGColor", 0, 0, 0, 0), 0, 0, 0);
    r_msg2_main_raw(shapeLayer, "setLineWidth:", &lineWidth, sizeof(lineWidth), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(shapeLayer, "setLineCap:", gLineCap, 0, 0, 0);

    double initialStroke = 0.0;
    r_msg2_main_raw(shapeLayer, "setStrokeEnd:", &initialStroke, sizeof(initialStroke), NULL, 0, NULL, 0, NULL, 0);
    
    r_msg2_main(ringLayer, "addSublayer:", shapeLayer, 0, 0, 0);
    gMagsafeShapeLayer = shapeLayer;
    r_msg2_main(shapeLayer, "release", 0, 0, 0, 0);

    // --- BOLT (Native) ---
    uint64_t UIImageClass = r_class("UIImage");
    uint64_t UIImageSymbolConfiguration = r_class("UIImageSymbolConfiguration");

    double boltSize = 120.0;
    uint64_t config = r_msg2_main_raw(UIImageSymbolConfiguration,"configurationWithPointSize:", &boltSize, sizeof(boltSize), NULL, 0, NULL, 0, NULL, 0);
    uint64_t boltName = r_nsstr_retained("bolt.fill");
    uint64_t boltImage = r_msg2_main(UIImageClass,"systemImageNamed:withConfiguration:", boltName, config, 0, 0);

    uint64_t UIImageViewClass = r_class("UIImageView");
    uint64_t boltView = r_msg2_main(r_msg2_main(UIImageViewClass, "alloc", 0, 0, 0, 0), "initWithImage:", boltImage, 0, 0, 0);
    r_msg2_main(boltView, "setTintColor:", gGreenColor, 0, 0, 0);

    struct { double x, y, w, h; } boltFrame = { (viewSize - 120)/2.0, (viewSize - 135)/2.0, 120.0, 135.0 };
    r_msg2_main_raw(boltView, "setFrame:", &boltFrame, sizeof(boltFrame), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(view, "addSubview:", boltView, 0, 0, 0);
    gMagsafeBoltView = boltView;
    
    r_msg2(boltName, "release", 0, 0, 0, 0);
    r_msg2_main(boltView, "release", 0, 0, 0, 0);

    // --- TEXTLAYER (Native) ---
    uint64_t CATextLayer = r_class("CATextLayer");
    uint64_t textLayer = r_msg2_main(r_msg2_main(CATextLayer, "alloc", 0, 0, 0, 0), "init", 0, 0, 0, 0);

    double textY = boltFrame.y + boltFrame.h + 120.0;
    struct { double x, y, w, h; } textBounds = { 0.0, 0.0, viewSize, 50.0 };
    r_msg2_main_raw(textLayer, "setBounds:", &textBounds, sizeof(textBounds), NULL, 0, NULL, 0, NULL, 0);

    struct { double x, y; } textPos = { viewSize / 2.0, textY }; 
    r_msg2_main_raw(textLayer, "setPosition:", &textPos, sizeof(textPos), NULL, 0, NULL, 0, NULL, 0);

    double scale = 3.0;
    r_msg2_main_raw(textLayer, "setContentsScale:", &scale, sizeof(scale), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(textLayer, "setFont:", gFontName, 0, 0, 0);

    double fontSize = 22.0;
    r_msg2_main_raw(textLayer, "setFontSize:", &fontSize, sizeof(fontSize), NULL, 0, NULL, 0, NULL, 0);
    r_msg2_main(textLayer, "setAlignmentMode:", gAlignMode, 0, 0, 0);

    uint64_t whiteColor = r_msg2_main(UIColor, "whiteColor", 0, 0, 0, 0);
    r_msg2_main(textLayer, "setForegroundColor:", r_msg2_main(whiteColor, "CGColor", 0, 0, 0, 0), 0, 0, 0);

    r_msg2_main(viewLayer, "addSublayer:", textLayer, 0, 0, 0);
    gMagsafeTextLayer = textLayer;
    r_msg2_main(textLayer, "release", 0, 0, 0, 0);

    // --- SETUP END ---
    r_msg2_main(view, "setHidden:", 1, 0, 0, 0);
    r_msg2_main(targetWindow, "addSubview:", view, 0, 0, 0);
    r_msg2_main(view, "release", 0, 0, 0, 0);
    
    gMagsafeView = view;
    return true;
}

bool magsafe_tweak_show_animation(float batteryPercentage, int style) {
    if (!gMagsafeView || !gMagsafeWindow) {
        return false;
    }
    
    int index = (int)(batteryPercentage * 100.0f);
    if (index < 0) index = 0;
    if (index > 100) index = 100;

    r_msg2_main(gMagsafeTextLayer, "setString:", gPercentStrings[index], 0, 0, 0);

    uint64_t targetCGColor = (batteryPercentage > 0.20) ? gGreenCGColor : gRedCGColor;
    r_msg2_main(gMagsafeShapeLayer, "setStrokeColor:", targetCGColor, 0, 0, 0);
    
    if (gMagsafeBoltView) {
        uint64_t targetUIColor = (batteryPercentage > 0.20) ? gGreenColor : gRedColor;
        r_msg2_main(gMagsafeBoltView, "setTintColor:", targetUIColor, 0, 0, 0);
    }

    double zeroVal = 0.0;
    r_msg2_main_raw(gMagsafeShapeLayer, "setStrokeEnd:", &zeroVal, sizeof(zeroVal), NULL, 0, NULL, 0, NULL, 0);

    r_msg2_main(gMagsafeView, "setHidden:", 0, 0, 0, 0);

    usleep(50000); 

    double endVal = (double)index / 100.0;
    r_msg2_main_raw(gMagsafeShapeLayer, "setStrokeEnd:", &endVal, sizeof(endVal), NULL, 0, NULL, 0, NULL, 0);

    return true;
}

bool magsafe_tweak_hide_animation(void) {
    if (gMagsafeView) {
        r_msg2_main(gMagsafeView, "setHidden:", 1, 0, 0, 0);
        double zeroVal = 0.0;
        r_msg2_main_raw(gMagsafeShapeLayer, "setStrokeEnd:", &zeroVal, sizeof(zeroVal), NULL, 0, NULL, 0, NULL, 0);
    }
    return true;
}

bool magsafe_tweak_stop_in_session(void) {
    if (gMagsafeView) r_msg2_main(gMagsafeView, "removeFromSuperview", 0, 0, 0, 0);
    if (gGreenColor) r_msg2_main(gGreenColor, "release", 0, 0, 0, 0);
    if (gRedColor) r_msg2_main(gRedColor, "release", 0, 0, 0, 0);
    if (gFontName) r_msg2(gFontName, "release", 0, 0, 0, 0);
    if (gAlignMode) r_msg2(gAlignMode, "release", 0, 0, 0, 0);
    if (gLineCap) r_msg2(gLineCap, "release", 0, 0, 0, 0);

    for (int i = 0; i <= 100; i++) {
        if (gPercentStrings[i]) {
            r_msg2(gPercentStrings[i], "release", 0, 0, 0, 0);
            gPercentStrings[i] = 0;
        }
    }

    gMagsafeView = 0;
    gMagsafeWindow = 0;
    gMagsafeShapeLayer = 0;
    gMagsafeTextLayer = 0;
    gMagsafeBoltView = 0;
    gGreenColor = 0;
    gRedColor = 0;
    gGreenCGColor = 0;
    gRedCGColor = 0;
    gCATransactionClass = 0;
    gFontName = 0;
    gAlignMode = 0;
    gLineCap = 0;
    return true;
}

void magsafe_tweak_forget_remote_state(void) {
    gMagsafeView = 0;
    gMagsafeWindow = 0;
    gMagsafeShapeLayer = 0;
    gMagsafeTextLayer = 0;
    gMagsafeBoltView = 0;
    gGreenColor = 0;
    gRedColor = 0;
    gGreenCGColor = 0;
    gRedCGColor = 0;
    gCATransactionClass = 0;
    gFontName = 0;
    gAlignMode = 0;
    gLineCap = 0;
    for (int i = 0; i <= 100; i++) {
        gPercentStrings[i] = 0;
    } 
}
