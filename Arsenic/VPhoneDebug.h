#pragma once

#include <stdbool.h>

#ifndef ARSENIC_VPHONE_DEBUG
#define ARSENIC_VPHONE_DEBUG 0
#endif

static inline bool arsenic_vphone_debug_build(void)
{
#if ARSENIC_VPHONE_DEBUG
    return true;
#else
    return false;
#endif
}
