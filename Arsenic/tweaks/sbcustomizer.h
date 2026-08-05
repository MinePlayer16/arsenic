//
//  sbcustomizer.h
//  Native port of the sbcustomizer dock+grid+labels patch.
//

#ifndef sbcustomizer_h
#define sbcustomizer_h

#import <stdbool.h>

bool sbcustomizer_apply(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                        bool arrangePages, int firstPageIcons, int otherPageIcons,
                        bool autoDockApp, const char *dockAppBundleID);
bool sbcustomizer_apply_in_session(int dockIcons, int hsCols, int hsRows, bool hideLabels,
                                   bool arrangePages, int firstPageIcons, int otherPageIcons,
                                   bool autoDockApp, const char *dockAppBundleID);

#endif
