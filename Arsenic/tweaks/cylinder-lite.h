//
//  cylinder-lite.h
//  RemoteCall-only core port of Reed Weichler/Ryannair05's Cylinder tweak.
//

#ifndef cylinder_lite_h
#define cylinder_lite_h

#include <stdbool.h>

typedef enum {
    CylinderLiteModeCubeInside     = 0,
    CylinderLiteModeCubeOutside    = 1,
    CylinderLiteModeCardHorizontal = 2,
    CylinderLiteModeBlinds         = 3,
} CylinderLiteMode;

typedef struct {
    CylinderLiteMode mode;
} CylinderLiteConfig;

bool cylinderlite_apply_in_session(CylinderLiteConfig config);
bool cylinderlite_stop_in_session(void);
void cylinderlite_tick_in_session(void);
bool cylinderlite_is_active(void);
void cylinderlite_forget_remote_state(void);

#endif /* cylinder_lite_h */