//
//  PresetManager.h
//  Arsenic
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

@interface PresetManager : NSObject

+ (instancetype)sharedManager;

- (NSArray<NSDictionary *> *)allPresets;
- (void)saveCurrentPresetNamed:(NSString *)name;
- (void)applyPresetNamed:(NSString *)name;
- (void)deletePresetNamed:(NSString *)name;

@end

NS_ASSUME_NONNULL_END