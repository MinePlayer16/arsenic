//
//  speculumlite.h
//  RemoteCall-only Lockscreen tweaking
//

#ifndef speculumlite_h
#define speculumlite_h

#import <stdbool.h>
#import <Foundation/Foundation.h>
#import <UIKit/UIKit.h>

#define kSpeculumMaxWidgets 16

typedef struct {
    char textTemplate[256];
    char fontPath[512];
    char hexColor[16];
    double scaleSize;
    double posX;
    double posY;
} SpeculumWidget;

typedef struct {
    bool enabled;
    bool hideDate;
    bool hideTime;
    int widgetCount;
    SpeculumWidget widgets[kSpeculumMaxWidgets];
} SpeculumLiteConfig;

bool speculumlite_apply_in_session(SpeculumLiteConfig config);

bool speculumlite_stop_in_session(void);

void speculumlite_forget_remote_state(void);

#endif /* speculumlite_h */