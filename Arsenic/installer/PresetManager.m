//
//  PresetManager.m
//  Arsenic
//

#import "PresetManager.h"
#import "PackageCatalog.h"
#import "PackageQueue.h"
#import "Package.h"
#import "SettingsViewController.h"
#import "../tweaks/RepoTweaks.h"

static NSString * const kArsenicPresetsKey = @"ArsenicSavedPresetsList";

@implementation PresetManager

+ (instancetype)sharedManager
{
    static PresetManager *manager = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        manager = [[PresetManager alloc] init];
    });
    return manager;
}

- (NSArray<NSDictionary *> *)allPresets
{
    NSArray *saved = [[NSUserDefaults standardUserDefaults] arrayForKey:kArsenicPresetsKey];
    return saved ?: @[];
}

// Maps tweaks enabled keys to their configuration in NSUserDefaults
- (NSArray<NSString *> *)settingsKeysForPackage:(Package *)package
{
    NSMutableArray<NSString *> *keys = [NSMutableArray array];
    NSString *enabledKey = package.enabledKey ?: @"";

    if (package.enabledKey.length > 0) {
        [keys addObject:package.enabledKey];
    }

    if ([enabledKey isEqualToString:kSettingsSBCEnabled]) {
        [keys addObjectsFromArray:@[
            kSettingsSBCDockIcons, kSettingsSBCCols, kSettingsSBCRows,
            kSettingsSBCHideLabels, kSettingsSBCArrangePages,
            kSettingsSBCFirstPageIcons, kSettingsSBCOtherPageIcons,
            kSettingsSBCAutoDockApp, kSettingsSBCDockAppBundleID
        ]];
    } else if ([enabledKey isEqualToString:kSettingsPowercuffEnabled]) {
        [keys addObject:kSettingsPowercuffLevel];
    } else if ([enabledKey isEqualToString:kSettingsStatBarEnabled]) {
        [keys addObjectsFromArray:@[
            kSettingsStatBarCelsius, kSettingsStatBarShowNet,
            kSettingsStatBarShowCPU, kSettingsStatBarShowLabels,
            kSettingsStatBarNetworkOnly, kSettingsStatBarRefreshRateSec
        ]];
    } else if ([enabledKey isEqualToString:kSettingsNSBarEnabled]) {
        [keys addObject:kSettingsNSBarPosition];
    } else if ([enabledKey isEqualToString:kSettingsNiceBarLiteEnabled]) {
        [keys addObjectsFromArray:@[
            @"NiceBarLiteCelsius", @"NiceBarLiteLayoutTopSideInset",
            @"NiceBarLiteLayoutBottomSideInset", @"NiceBarLiteLayoutTopY",
            @"NiceBarLiteLayoutBottomY", @"NiceBarLiteLayoutCenterX"
        ]];
        for (NSInteger i = 0; i < 5; i++) {
            [keys addObject:[NSString stringWithFormat:@"NiceBarLiteSlotKind%ld", (long)i]];
            [keys addObject:[NSString stringWithFormat:@"NiceBarLiteSlotSystem%ld", (long)i]];
            [keys addObject:[NSString stringWithFormat:@"NiceBarLiteSlotText%ld", (long)i]];
            [keys addObject:[NSString stringWithFormat:@"NiceBarLiteSlotTime%ld", (long)i]];
            [keys addObject:[NSString stringWithFormat:@"NiceBarLiteSlotWeather%ld", (long)i]];
        }
    } else if ([enabledKey isEqualToString:kSettingsGravityLiteEnabled]) {
        [keys addObjectsFromArray:@[
            kSettingsGravityLiteDockEnabled, kSettingsGravityLiteMagnitudePct,
            kSettingsGravityLiteBouncePct, kSettingsGravityLiteFrictionPct,
            kSettingsGravityLiteResistancePct, @"GravityLiteAngularResistancePct"
        ]];
    } else if ([enabledKey isEqualToString:kSettingsSpeculumLiteEnabled]) {
        [keys addObjectsFromArray:@[
            @"SpeculumLiteHideDate", @"SpeculumLiteHideTime", @"SpeculumLiteWidgets"
        ]];
    } else if ([enabledKey isEqualToString:kSettingsNotweaficationsEnabled]) {
        [keys addObject:@"NotweaficationsAppColors"];
    } else if ([enabledKey isEqualToString:kSettingsActionSwitchEnabled]) {
        [keys addObject:@"ActionSwitchMode"];
    } else if ([enabledKey isEqualToString:kSettingsRSSIDisplayEnabled]) {
        [keys addObjectsFromArray:@[kSettingsRSSIDisplayWifi, kSettingsRSSIDisplayCell]];
    } else if ([enabledKey isEqualToString:kSettingsLiveWPEnabled]) {
        [keys addObject:kSettingsLiveWPVideoPath];
    } else if ([enabledKey isEqualToString:kSettingsThemerEnabled] ||
               [enabledKey isEqualToString:kSettingsSnowBoardLiteEnabled]) {
        [keys addObjectsFromArray:@[
            kSettingsThemerThemeID, kSettingsThemerCustomThemePath,
            kSettingsThemerCustomThemeName, kSettingsSnowBoardLiteSelectedThemeID
        ]];
    } else if ([enabledKey isEqualToString:kSettingsFastLockXLiteEnabled]) {
        [keys addObjectsFromArray:@[
            @"FastLockXLiteBlockMusic", @"FastLockXLiteBlockFlashlight", 
            @"FastLockXLiteBlockLowPower", @"FastLockXLiteRetryInterval"
        ]];
    } else if ([enabledKey isEqualToString:@"LocationSimEnabled"]) {
        [keys addObjectsFromArray:@[
            @"LocationSimLatitude", @"LocationSimLongitude", 
            @"LocationSimAltitude", @"LocationSimHorizontalAccuracy", 
            @"LocationSimHostProcess"
        ]];
    } else if ([enabledKey isEqualToString:kSettingsMagsafeEnabled]) {
        [keys addObject:@"MagsafeStyle"];
    } else if ([enabledKey isEqualToString:kSettingsDSDragCoefficientEnabled]) {
        [keys addObject:kSettingsDSDragCoefficientValue];
    } else if ([enabledKey isEqualToString:kSettingsLayoutExtrasEnabled]) {
        [keys addObjectsFromArray:@[
            kSettingsLayoutHomeExtraLeft, kSettingsLayoutHomeExtraRight,
            kSettingsLayoutHomeExtraTop, kSettingsLayoutHomeExtraBottom,
            kSettingsLayoutDockExtraHorizontal, kSettingsLayoutHomeScalePct,
            kSettingsLayoutDockScalePct
        ]];
    }

    // RepoTweaks params
    if (package.kind == PackageInstallKindRepoTweak && package.repoURL.length > 0 && package.repoTweakID.length > 0) {
        [keys addObject:repotweaks_enabled_defaults_key(package.repoURL, package.repoTweakID)];
        [keys addObject:repotweaks_values_defaults_key(package.repoURL, package.repoTweakID)];
        [keys addObject:repotweaks_script_defaults_key(package.repoURL, package.repoTweakID)];
    }

    return keys;
}

- (void)saveCurrentPresetNamed:(NSString *)name
{
    if (name.length == 0) return;

    PackageQueue *queue = [PackageQueue sharedQueue];
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    // search queued for install tweaks
    NSMutableSet<Package *> *activePackages = [NSMutableSet set];
    [activePackages addObjectsFromArray:queue.queuedInstalls];

    for (Package *pkg in [PackageCatalog allPackages]) {
        if (pkg.isInstalled) {
            BOOL queuedForUninstall = NO;
            for (Package *u in queue.queuedUninstalls) {
                if ([u.identifier isEqualToString:pkg.identifier]) {
                    queuedForUninstall = YES;
                    break;
                }
            }
            if (!queuedForUninstall) {
                [activePackages addObject:pkg];
            }
        }
    }

    // package identifier + their settings
    NSMutableArray<NSString *> *packageIDs = [NSMutableArray array];
    NSMutableDictionary *savedSettings = [NSMutableDictionary dictionary];

    for (Package *pkg in activePackages) {
        if (pkg.identifier.length > 0) {
            [packageIDs addObject:pkg.identifier];
        }
        NSArray<NSString *> *keys = [self settingsKeysForPackage:pkg];
        for (NSString *key in keys) {
            id val = [defaults objectForKey:key];
            if (val) {
                savedSettings[key] = val;
            }
        }
    }

    NSMutableArray *presets = [[self allPresets] mutableCopy];
    [presets filterUsingPredicate:[NSPredicate predicateWithFormat:@"name != %@", name]];

    [presets addObject:@{
        @"name": name,
        @"packageIDs": packageIDs,
        @"settings": savedSettings,
        @"createdAt": [NSDate date]
    }];

    [defaults setObject:presets forKey:kArsenicPresetsKey];
    [defaults synchronize];
}

- (void)applyPresetNamed:(NSString *)name
{
    NSDictionary *targetPreset = nil;
    for (NSDictionary *p in [self allPresets]) {
        if ([p[@"name"] isEqualToString:name]) {
            targetPreset = p;
            break;
        }
    }
    if (!targetPreset) return;

    NSArray<NSString *> *presetPackageIDs = targetPreset[@"packageIDs"] ?: @[];
    NSDictionary *presetSettings = targetPreset[@"settings"] ?: @{};

    PackageQueue *queue = [PackageQueue sharedQueue];
    [queue clear]; // clear current queue

    // restore saved settings into NSUserDefaults
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
    for (NSString *key in presetSettings) {
        [defaults setObject:presetSettings[key] forKey:key];
    }
    [defaults synchronize];

    NSArray<Package *> *allPackages = [PackageCatalog allPackages];
    for (Package *pkg in allPackages) {
        BOOL inPreset = [presetPackageIDs containsObject:pkg.identifier];

        if (inPreset) {
            if (!pkg.isInstalled) {
                // Not installed yet -> queue install
                [queue queueIntent:PackageQueueIntentInstall forPackage:pkg];
            }
        } else {
            if (pkg.isInstalled) {
                // Installed but not in this preset -> queue uninstall
                [queue queueIntent:PackageQueueIntentUninstall forPackage:pkg];
            } else if (pkg.enabledKey.length > 0) {
                // Ensure unused toggle tweak is off in defaults
                [defaults setBool:NO forKey:pkg.enabledKey];
            }
        }
    }
    [defaults synchronize];

    [[NSNotificationCenter defaultCenter] postNotificationName:PackageQueueDidChangeNotification object:queue];
    [[NSNotificationCenter defaultCenter] postNotificationName:@"SettingsActionsDidCompleteNotification" object:nil];
}

- (void)deletePresetNamed:(NSString *)name
{
    NSMutableArray *presets = [[self allPresets] mutableCopy];
    [presets filterUsingPredicate:[NSPredicate predicateWithFormat:@"name != %@", name]];
    [[NSUserDefaults standardUserDefaults] setObject:presets forKey:kArsenicPresetsKey];
    [[NSUserDefaults standardUserDefaults] synchronize];
}

@end