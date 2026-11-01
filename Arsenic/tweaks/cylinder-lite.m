//
//  cylinder-lite.m
//  RemoteCall-only core port of Cylinder (Cube Inside, Cube Outside, Card Horizontal, Blinds).
//

#import "cylinder-lite.h"
#import "remote_objc.h"
#import "sb_walk.h"
#import "../TaskRop/RemoteCall.h"
#import "../LogTextView.h"

#import <Foundation/Foundation.h>
#import <math.h>
#import <stdio.h>
#import <stdlib.h>
#import <string.h>
#import <unistd.h>

typedef struct {
    double x, y, w, h;
} CL_CGRect;

typedef struct {
    double x, y;
} CL_CGPoint;

typedef struct {
    double m11, m12, m13, m14;
    double m21, m22, m23, m24;
    double m31, m32, m33, m34;
    double m41, m42, m43, m44;
} CL_CATransform3D;

#define CL_MAX_PAGES 16
#define CL_MAX_ICONS 32

typedef struct {
    uint64_t pageView;
    uint64_t pageLayer;
    double pageOriginX;
    double pageWidth;
    double pageHeight;
    bool isFlat;
    bool isZeroed;
    int iconCount;
    uint64_t iconLayers[CL_MAX_ICONS];
    bool iconIsFlat[CL_MAX_ICONS];
} CylinderPageCache;

static volatile bool g_cl_active = false;
static volatile int s_cl_in_tick = 0;
static CylinderLiteConfig g_cl_config = { .mode = CylinderLiteModeCubeInside };

static uint64_t g_cl_scroll_view = 0;
static uint64_t g_cl_no_anim_dict = 0;
static double g_cl_screen_width = 0.0;
static int g_cl_page_count = 0;
static CylinderPageCache g_cl_pages[CL_MAX_PAGES];

static double s_cl_last_offset_x = -99999.0;
static bool s_cl_is_settled = false;

// matrix and helpers
static CL_CATransform3D cl_transform3d_identity(void) {
    CL_CATransform3D t = {0};
    t.m11 = 1.0; t.m22 = 1.0; t.m33 = 1.0; t.m44 = 1.0;
    return t;
}

static CL_CATransform3D cl_transform3d_zero_scale(void) {
    CL_CATransform3D t = {0};
    t.m44 = 1.0;
    return t;
}

static CL_CATransform3D cl_make_cube_outside_matrix(double angle, double tx, double tz, double persp) {
    CL_CATransform3D t = cl_transform3d_identity();
    double c = cos(angle);
    double s = sin(angle);
    t.m11 = c;
    t.m14 = -s * persp;
    t.m31 = s;
    t.m33 = c;
    t.m34 = c * persp;
    t.m41 = tx;
    t.m44 = 1.0 + (tz * persp);
    return t;
}

static CL_CATransform3D cl_make_perspective_y_with_screen_offset(double angle,
                                                                 double dx3D,
                                                                 double dz3D,
                                                                 double screenOffsetX,
                                                                 double persp)
{
    CL_CATransform3D t = cl_transform3d_identity();
    double c = cos(angle);
    double s = sin(angle);
    double m14 = -s * persp;
    double m34 = c * persp;
    double m44 = 1.0 + (dz3D * persp);

    t.m11 = c + (screenOffsetX * m14);
    t.m14 = m14;
    t.m31 = s + (screenOffsetX * m34);
    t.m33 = c;
    t.m34 = m34;
    t.m41 = dx3D + (screenOffsetX * m44);
    t.m44 = m44;
    return t;
}

static uint64_t cl_safe_msg(uint64_t obj, const char *selName,
                            uint64_t a0, uint64_t a1, uint64_t a2, uint64_t a3)
{
    if (!r_is_objc_ptr(obj) || !selName) return 0;
    if (!r_responds_main(obj, selName)) return 0;
    return r_msg2_main(obj, selName, a0, a1, a2, a3);
}

static bool cl_get_rect(uint64_t obj, const char *selName, CL_CGRect *out)
{
    if (!r_is_objc_ptr(obj) || !selName || !out) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(obj, selName,
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static bool cl_get_point(uint64_t obj, const char *selName, CL_CGPoint *out)
{
    if (!r_is_objc_ptr(obj) || !selName || !out) return false;
    memset(out, 0, sizeof(*out));
    return r_msg2_main_struct_ret(obj, selName,
                                  out, sizeof(*out),
                                  NULL, 0, NULL, 0, NULL, 0, NULL, 0);
}

static void cl_set_layer_transform3d_fast(uint64_t layer, CL_CATransform3D t) {
    if (!r_is_objc_ptr(layer)) return;
    r_msg2_main_raw(layer, "setTransform:", &t, sizeof(t), NULL, 0, NULL, 0, NULL, 0);
}

// so that the folders don't turn black at certain inclinations
static void cl_set_rasterized(uint64_t layer, bool rasterized) {
    if (!r_is_objc_ptr(layer)) return;
    uint64_t val = rasterized ? 1 : 0;
    r_msg2_main(layer, "setShouldRasterize:", val, 0, 0, 0);
    if (rasterized) {
        double scale = 3.0;
        r_msg2_main_raw(layer, "setRasterizationScale:", &scale, sizeof(double), NULL, 0, NULL, 0, NULL, 0);
    }
}

// cache icon layers
static void cl_cache_page_icon_layers_once(CylinderPageCache *p) {
    if (!r_is_objc_ptr(p->pageView)) return;

    if (r_responds_main(p->pageView, "showAllIcons")) {
        r_msg2_main(p->pageView, "showAllIcons", 0, 0, 0, 0);
    }
    if (r_responds_main(p->pageView, "layoutIconsNow")) {
        r_msg2_main(p->pageView, "layoutIconsNow", 0, 0, 0, 0);
    }

    uint64_t subviews = r_msg2_main(p->pageView, "subviews", 0, 0, 0, 0);
    uint64_t subCount = r_is_objc_ptr(subviews) ? r_msg2(subviews, "count", 0, 0, 0, 0) : 0;
    if (subCount > CL_MAX_ICONS) subCount = CL_MAX_ICONS;

    CL_CATransform3D ident3d = cl_transform3d_identity();
    p->iconCount = 0;

    for (uint64_t j = 0; j < subCount; j++) {
        uint64_t icon = r_msg2(subviews, "objectAtIndex:", j, 0, 0, 0);
        if (!r_is_objc_ptr(icon)) continue;

        uint64_t iconLayer = r_msg2_main(icon, "layer", 0, 0, 0, 0);
        if (!r_is_objc_ptr(iconLayer)) continue;

        if (r_is_objc_ptr(g_cl_no_anim_dict)) {
            r_msg2_main(iconLayer, "setActions:", g_cl_no_anim_dict, 0, 0, 0);
        }
        cl_set_layer_transform3d_fast(iconLayer, ident3d);

        int idx = p->iconCount++;
        p->iconLayers[idx] = iconLayer;
        p->iconIsFlat[idx] = true;
    }
}

static void cl_reset_page(CylinderPageCache *p) {
    CL_CATransform3D ident3d = cl_transform3d_identity();
    cl_set_layer_transform3d_fast(p->pageLayer, ident3d);
    
    // disable rasterization when flat to restore live blur rendering
    cl_set_rasterized(p->pageLayer, false);

    if (g_cl_config.mode == CylinderLiteModeBlinds) {
        for (int j = 0; j < p->iconCount; j++) {
            if (!p->iconIsFlat[j]) {
                cl_set_layer_transform3d_fast(p->iconLayers[j], ident3d);
                cl_set_rasterized(p->iconLayers[j], false);
                p->iconIsFlat[j] = true;
            }
        }
    }

    p->isFlat = true;
    p->isZeroed = false;
}

// cache builder
static bool cl_build_cache(CylinderLiteConfig config) {
    uint64_t cls = r_class("SBIconController");
    if (!r_is_objc_ptr(cls)) return false;
    uint64_t ctrl = r_msg2(cls, "sharedInstance", 0, 0, 0, 0);
    if (!r_is_objc_ptr(ctrl)) return false;

    uint64_t mgr = cl_safe_msg(ctrl, "iconManager", 0, 0, 0, 0);
    uint64_t rootFC = cl_safe_msg(mgr, "rootFolderController", 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootFC)) rootFC = cl_safe_msg(ctrl, "_rootFolderController", 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootFC)) rootFC = cl_safe_msg(ctrl, "rootFolderController", 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootFC)) return false;

    uint64_t rootView = cl_safe_msg(rootFC, "rootFolderView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(rootView)) return false;

    uint64_t scrollView = cl_safe_msg(rootView, "scrollView", 0, 0, 0, 0);
    if (!r_is_objc_ptr(scrollView)) return false;

    CL_CGRect scrollBounds = {0};
    if (!cl_get_rect(scrollView, "bounds", &scrollBounds) || scrollBounds.w <= 1.0) return false;

    uint64_t lists = cl_safe_msg(rootFC, "iconListViews", 0, 0, 0, 0);
    if (!r_is_objc_ptr(lists)) return false;

    uint64_t count = r_msg2(lists, "count", 0, 0, 0, 0);
    if (count == 0) return false;
    if (count > CL_MAX_PAGES) count = CL_MAX_PAGES;

    if (!r_is_objc_ptr(g_cl_no_anim_dict)) {
        uint64_t dictCls = r_class("NSMutableDictionary");
        uint64_t nullCls = r_class("NSNull");
        if (r_is_objc_ptr(dictCls) && r_is_objc_ptr(nullCls)) {
            g_cl_no_anim_dict = r_msg2(dictCls, "new", 0, 0, 0, 0);
            uint64_t nullObj = r_msg2(nullCls, "null", 0, 0, 0, 0);
            if (r_is_objc_ptr(g_cl_no_anim_dict) && r_is_objc_ptr(nullObj)) {
                uint64_t k1 = r_nsstr_retained("transform");
                uint64_t k2 = r_nsstr_retained("zPosition");
                uint64_t k3 = r_nsstr_retained("opacity");
                uint64_t k4 = r_nsstr_retained("position");
                r_msg2(g_cl_no_anim_dict, "setObject:forKey:", nullObj, k1, 0, 0);
                r_msg2(g_cl_no_anim_dict, "setObject:forKey:", nullObj, k2, 0, 0);
                r_msg2(g_cl_no_anim_dict, "setObject:forKey:", nullObj, k3, 0, 0);
                r_msg2(g_cl_no_anim_dict, "setObject:forKey:", nullObj, k4, 0, 0);
                if (k1) r_msg2(k1, "release", 0, 0, 0, 0);
                if (k2) r_msg2(k2, "release", 0, 0, 0, 0);
                if (k3) r_msg2(k3, "release", 0, 0, 0, 0);
                if (k4) r_msg2(k4, "release", 0, 0, 0, 0);
            }
        }
    }

    g_cl_config = config;
    int validPages = 0;

    for (uint64_t i = 0; i < count; i++) {
        uint64_t pageView = r_msg2(lists, "objectAtIndex:", i, 0, 0, 0);
        if (!r_is_objc_ptr(pageView)) continue;

        uint64_t pageLayer = r_msg2_main(pageView, "layer", 0, 0, 0, 0);
        if (!r_is_objc_ptr(pageLayer)) continue;

        if (r_is_objc_ptr(g_cl_no_anim_dict)) {
            r_msg2_main(pageLayer, "setActions:", g_cl_no_anim_dict, 0, 0, 0);
        }

        cl_set_layer_transform3d_fast(pageLayer, cl_transform3d_identity());
        cl_set_rasterized(pageLayer, false);

        CL_CGRect pageBounds = {0};
        CL_CGPoint pageCenter = {0};
        if (!cl_get_rect(pageView, "bounds", &pageBounds) ||
            !cl_get_point(pageView, "center", &pageCenter)) continue;

        CylinderPageCache *p = &g_cl_pages[validPages];
        memset(p, 0, sizeof(*p));
        p->pageView = pageView;
        p->pageLayer = pageLayer;
        p->pageWidth = pageBounds.w > 1.0 ? pageBounds.w : scrollBounds.w;
        p->pageHeight = pageBounds.h;
        p->pageOriginX = pageCenter.x - (scrollBounds.w * 0.5);
        p->isFlat = true;
        p->isZeroed = false;

        if (config.mode == CylinderLiteModeBlinds) {
            cl_cache_page_icon_layers_once(p);
        }
        validPages++;
    }

    if (validPages <= 0) return false;

    g_cl_scroll_view = scrollView;
    g_cl_screen_width = scrollBounds.w;
    g_cl_page_count = validPages;
    s_cl_last_offset_x = -99999.0;
    s_cl_is_settled = false;
    g_cl_active = true;

    printf("[CYLINDER] Pre-cached %d pages (mode=%d, width=%.1f pt)\n",
           validPages, (int)config.mode, scrollBounds.w);
    return true;
}

// tick
void cylinderlite_tick_in_session(void)
{
    if (!g_cl_active || !r_is_objc_ptr(g_cl_scroll_view) || g_cl_screen_width <= 0.0) return;
    if (__sync_lock_test_and_set(&s_cl_in_tick, 1)) return;

    uint32_t oldSettle = r_settle_us(0);

    CL_CGPoint offset = {0};
    if (!r_msg2_main_struct_ret(g_cl_scroll_view, "contentOffset", &offset, sizeof(offset),
                                NULL, 0, NULL, 0, NULL, 0, NULL, 0)) {
        r_settle_us(oldSettle);
        __sync_lock_release(&s_cl_in_tick);
        return;
    }

    if (fabs(offset.x - s_cl_last_offset_x) < 0.02) {
        if (s_cl_is_settled) {
            r_settle_us(oldSettle);
            __sync_lock_release(&s_cl_in_tick);
            return;
        }
        s_cl_is_settled = true;
    } else {
        s_cl_is_settled = false;
    }
    s_cl_last_offset_x = offset.x;

    // ---------------------------------------------------------
    // MODE 0: CUBE INSIDE
    // ---------------------------------------------------------
    if (g_cl_config.mode == CylinderLiteModeCubeInside) {
        double Rx = g_cl_screen_width * 0.5;
        double persp = -1.0 / 1100.0;

        for (int i = 0; i < g_cl_page_count; i++) {
            CylinderPageCache *p = &g_cl_pages[i];
            double progress = (offset.x - p->pageOriginX) / g_cl_screen_width;

            if (fabs(progress) < 0.003 || progress <= -0.98 || progress >= 0.98 || (s_cl_is_settled && fabs(progress) < 0.03)) {
                if (!p->isFlat) {
                    cl_reset_page(p);
                }
                continue;
            }

            if (p->isFlat) {
                cl_set_rasterized(p->pageLayer, true);
                p->isFlat = false;
            }

            double angle = progress * M_PI_2;
            double offset_pixels = progress * g_cl_screen_width;
            double dx = -sin(angle) * Rx;
            double dz = (1.0 - cos(angle)) * Rx;

            CL_CATransform3D t = cl_make_perspective_y_with_screen_offset(angle, dx, dz, offset_pixels, persp);
            cl_set_layer_transform3d_fast(p->pageLayer, t);
        }

        r_settle_us(oldSettle);
        __sync_lock_release(&s_cl_in_tick);
        return;
    }

    // ---------------------------------------------------------
    // MODE 1: CUBE OUTSIDE
    // ---------------------------------------------------------
    if (g_cl_config.mode == CylinderLiteModeCubeOutside) {
        double Rx = g_cl_screen_width * 0.5;
        double persp = -1.0 / 650.0;

        for (int i = 0; i < g_cl_page_count; i++) {
            CylinderPageCache *p = &g_cl_pages[i];
            double progress = (offset.x - p->pageOriginX) / g_cl_screen_width;

            if (fabs(progress) < 0.003 || progress <= -0.98 || progress >= 0.98 || (s_cl_is_settled && fabs(progress) < 0.03)) {
                if (!p->isFlat) {
                    cl_reset_page(p);
                }
                continue;
            }

            if (p->isFlat) {
                cl_set_rasterized(p->pageLayer, true);
                p->isFlat = false;
            }

            double angle = -progress * M_PI_2;
            double offset_pixels = progress * g_cl_screen_width;
            double dx = sin(angle) * Rx;
            double dz = (cos(angle) - 1.0) * Rx;

            CL_CATransform3D t = cl_make_cube_outside_matrix(angle, offset_pixels + dx, dz, persp);
            cl_set_layer_transform3d_fast(p->pageLayer, t);
        }

        r_settle_us(oldSettle);
        __sync_lock_release(&s_cl_in_tick);
        return;
    }

    // ---------------------------------------------------------
    // MODE 2: CARD (HORIZONTAL) 
    // ---------------------------------------------------------
    if (g_cl_config.mode == CylinderLiteModeCardHorizontal) {
        double persp = -1.0 / 850.0;

        for (int i = 0; i < g_cl_page_count; i++) {
            CylinderPageCache *p = &g_cl_pages[i];
            double pageOffset = offset.x - p->pageOriginX;
            double progress = pageOffset / g_cl_screen_width;
            double absProg = fabs(progress);

            if (absProg < 0.0001 || absProg > 0.9999) {
                if (!p->isFlat || p->isZeroed) {
                    cl_reset_page(p);
                }
                continue;
            }

            if (absProg > 0.50) {
                if (!p->isZeroed) {
                    cl_set_layer_transform3d_fast(p->pageLayer, cl_transform3d_zero_scale());
                    p->isZeroed = true;
                }
                continue;
            }

            if (p->isFlat || p->isZeroed) {
                cl_set_rasterized(p->pageLayer, true);
                p->isZeroed = false;
                p->isFlat = false;
            }

            double angle = -progress * M_PI; 
            
            CL_CATransform3D t = cl_make_perspective_y_with_screen_offset(angle, 0.0, 0.0, pageOffset, persp);
            cl_set_layer_transform3d_fast(p->pageLayer, t);
        }

        r_settle_us(oldSettle);
        __sync_lock_release(&s_cl_in_tick);
        return;
    }

    // ---------------------------------------------------------
    // MODE 3: BLINDS //this one still needs some work (not too smooth)
    // ---------------------------------------------------------
    if (g_cl_config.mode == CylinderLiteModeBlinds) {
        double persp = -1.0 / 500.0;
        double magnitude = 0.55;
        CL_CATransform3D ident3d = cl_transform3d_identity();

        for (int pIdx = 0; pIdx < g_cl_page_count; pIdx++) {
            CylinderPageCache *p = &g_cl_pages[pIdx];
            double pageOffset = offset.x - p->pageOriginX;
            double percent = pageOffset / g_cl_screen_width;
            double absPct = fabs(percent);

            if (absPct < 0.004 || absPct >= 0.98 || (s_cl_is_settled && absPct < 0.035)) {
                if (!p->isFlat) {
                    cl_reset_page(p);
                }
                continue;
            }

            p->isFlat = false;
            int n = p->iconCount;

            for (int i = 0; i < n; i++) {
                double seed = fmod(sin((double)(i + 1) * 12.9898) * 43758.5453, 1.0);
                if (seed < 0.0) seed += 1.0;

                double start = seed * (1.0 - magnitude);
                double span = magnitude;
                double iconPct = 0.0;
                if (absPct > start) {
                    iconPct = fmin((absPct - start) / span, 1.0);
                }

                if (iconPct <= 0.001 || iconPct >= 0.999) {
                    if (!p->iconIsFlat[i]) {
                        cl_set_layer_transform3d_fast(p->iconLayers[i], ident3d);
                        cl_set_rasterized(p->iconLayers[i], false);
                        p->iconIsFlat[i] = true;
                    }
                    continue;
                }

                if (p->iconIsFlat[i]) {
                    cl_set_rasterized(p->iconLayers[i], true);
                    p->iconIsFlat[i] = false;
                }
                
                double dir = (percent < 0.0) ? -1.0 : 1.0;
                double angle = dir * (2.0 * M_PI * iconPct);
                CL_CATransform3D iconT = cl_make_cube_outside_matrix(angle, 0.0, 0.0, persp);
                cl_set_layer_transform3d_fast(p->iconLayers[i], iconT);
            }
        }

        r_settle_us(oldSettle);
        __sync_lock_release(&s_cl_in_tick);
        return;
    }

    r_settle_us(oldSettle);
    __sync_lock_release(&s_cl_in_tick);
}

bool cylinderlite_apply_in_session(CylinderLiteConfig config)
{
    return cl_build_cache(config);
}

bool cylinderlite_stop_in_session(void)
{
    g_cl_active = false;
    for (int i = 0; i < g_cl_page_count; i++) {
        cl_reset_page(&g_cl_pages[i]);
    }
    g_cl_scroll_view = 0;
    g_cl_page_count = 0;
    printf("[CYLINDER] Stopped and restored pages.\n");
    return true;
}

bool cylinderlite_is_active(void)
{
    return g_cl_active;
}

void cylinderlite_forget_remote_state(void)
{
    g_cl_active = false;
    g_cl_scroll_view = 0;
    g_cl_page_count = 0;
    g_cl_no_anim_dict = 0;
}