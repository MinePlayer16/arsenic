//
//  experimental_tweaks.h
//  Arsenic
//
//  Experimental and beta tweak APIs are part of the public source tree.
//

#ifndef experimental_tweaks_h
#define experimental_tweaks_h

#include <stdbool.h>
#include <stdint.h>

#include "location_sim.h"
#include "call_recording_sound.h"

#import "experimental/rssidisplay.h"
#import "experimental/typebanner.h"
#import "experimental/notificationisland.h"
#import "experimental/stagestrip.h"
#import "experimental/ipadecryptor.h"
#import "experimental/fastlockx_lite.h"

#define ARSENIC_EXPERIMENTAL_TWEAKS_AVAILABLE 1

static inline bool arsenic_experimental_tweaks_available(void)
{
    return true;
}

#endif /* experimental_tweaks_h */
