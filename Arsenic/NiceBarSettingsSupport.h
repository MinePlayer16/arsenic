//
//  NiceBarSettingsSupport.h
//  Arsenic
//
//  NiceBar Lite Settings UI and weather helpers adapted from
//  https://github.com/d1y/cyanide-ios (AGPL-3.0).
//

#import <UIKit/UIKit.h>
#import "tweaks/nicebarlite.h"

typedef void (^ArsenicNiceBarWeatherCompletion)(BOOL ok,
                                                NSString *text,
                                                NSNumber *temp,
                                                NSNumber *code,
                                                BOOL fetched);

NSString *ArsenicNiceBarSystemDescription(NSInteger item);
NSString *ArsenicNiceBarSystemName(NSInteger item);
NSString *ArsenicNiceBarSystemLanguageName(NSString *language);
NSString *ArsenicNiceBarTimeFormatName(NSString *format);
NSString *ArsenicNiceBarPreviewForTimeFormat(NSString *format);
NSString *ArsenicNiceBarWeatherSummary(NSInteger code, BOOL chinese);

@interface ArsenicNiceBarWeatherRefresher : NSObject
+ (instancetype)sharedRefresher;
- (void)refreshWeatherForce:(BOOL)force
                 useCelsius:(BOOL)useCelsius
                 completion:(ArsenicNiceBarWeatherCompletion)completion;
@end

@interface ArsenicNiceBarTrafficHistoryViewController : UITableViewController
@end

typedef void (^ArsenicNiceBarTimeFormatSelection)(NSString *format);

@interface ArsenicNiceBarTimePresetPickerViewController : UITableViewController
- (instancetype)initWithSlotTitle:(NSString *)slotTitle
                   selectedFormat:(NSString *)selectedFormat
                        selection:(ArsenicNiceBarTimeFormatSelection)selection;
@end

typedef void (^ArsenicNiceBarSystemItemSelection)(NSInteger item, NSString *language);

@interface ArsenicNiceBarSystemItemPickerViewController : UITableViewController
- (instancetype)initWithSlotTitle:(NSString *)slotTitle
                     selectedItem:(NSInteger)selectedItem
                 selectedLanguage:(NSString *)selectedLanguage
                        selection:(ArsenicNiceBarSystemItemSelection)selection;
@end
