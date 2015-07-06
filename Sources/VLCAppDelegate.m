/*****************************************************************************
 * VLCAppDelegate.m
 * VLC for iOS
 *****************************************************************************
 * Copyright (c) 2013-2015 VideoLAN. All rights reserved.
 * $Id$
 *
 * Authors: Felix Paul Kühne <fkuehne # videolan.org>
 *          Gleb Pinigin <gpinigin # gmail.com>
 *          Jean-Romain Prévost <jr # 3on.fr>
 *          Luis Fernandes <zipleen # gmail.com>
 *          Carola Nitz <nitz.carola # googlemail.com>
 *          Tamas Timar <ttimar.vlc # gmail.com>
 *          Tobias Conradi <videolan # tobias-conradi.de>
 *
 * Refer to the COPYING file of the official project for license.
 *****************************************************************************/

#import "VLCAppDelegate.h"
#import "VLCMediaFileDiscoverer.h"
#import "NSString+SupportedMedia.h"
#import "UIDevice+VLC.h"
#import "VLCPlaylistViewController.h"
#import "VLCHTTPUploaderController.h"
#import "VLCMigrationViewController.h"
#import <BoxSDK/BoxSDK.h>
#import "VLCNotificationRelay.h"
#import "VLCPlaybackController.h"
#import "VLCWatchMessage.h"
#import "VLCPlaybackController+MediaLibrary.h"
#import "VLCPlayerDisplayController.h"
#import <MediaPlayer/MediaPlayer.h>
#import <DropboxSDK/DropboxSDK.h>
#import <HockeySDK/HockeySDK.h>
#import "VLCSidebarController.h"
#import "VLCKeychainCoordinator.h"
#import "VLCActivityManager.h"

NSString *const VLCDropboxSessionWasAuthorized = @"VLCDropboxSessionWasAuthorized";

#define BETA_DISTRIBUTION 1

@interface VLCAppDelegate () <VLCMediaFileDiscovererDelegate>
{
    BOOL _passcodeValidated;
    BOOL _isRunningMigration;
    BOOL _isComingFromHandoff;
}

@end

@implementation VLCAppDelegate

+ (void)initialize
{
    NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];

    NSNumber *skipLoopFilterDefaultValue;
    int deviceSpeedCategory = [[UIDevice currentDevice] speedCategory];
    if (deviceSpeedCategory < 3)
        skipLoopFilterDefaultValue = kVLCSettingSkipLoopFilterNonKey;
    else
        skipLoopFilterDefaultValue = kVLCSettingSkipLoopFilterNonRef;

    NSDictionary *appDefaults = @{kVLCSettingPasscodeKey : @"",
                                  kVLCSettingContinueAudioInBackgroundKey : @(YES),
                                  kVLCSettingStretchAudio : @(NO),
                                  kVLCSettingTextEncoding : kVLCSettingTextEncodingDefaultValue,
                                  kVLCSettingSkipLoopFilter : skipLoopFilterDefaultValue,
                                  kVLCSettingSubtitlesFont : kVLCSettingSubtitlesFontDefaultValue,
                                  kVLCSettingSubtitlesFontColor : kVLCSettingSubtitlesFontColorDefaultValue,
                                  kVLCSettingSubtitlesFontSize : kVLCSettingSubtitlesFontSizeDefaultValue,
                                  kVLCSettingSubtitlesBoldFont: kVLCSettingSubtitlesBoldFontDefaultValue,
                                  kVLCSettingDeinterlace : kVLCSettingDeinterlaceDefaultValue,
                                  kVLCSettingNetworkCaching : kVLCSettingNetworkCachingDefaultValue,
                                  kVLCSettingPlaybackGestures : @(YES),
                                  kVLCSettingVideoFullscreenPlayback : @(YES),
                                  kVLCSettingFTPTextEncoding : kVLCSettingFTPTextEncodingDefaultValue,
                                  kVLCSettingWiFiSharingIPv6 : kVLCSettingWiFiSharingIPv6DefaultValue,
                                  kVLCSettingEqualizerProfile : kVLCSettingEqualizerProfileDefaultValue,
                                  kVLCSettingPlaybackForwardSkipLength : kVLCSettingPlaybackForwardSkipLengthDefaultValue,
                                  kVLCSettingPlaybackBackwardSkipLength : kVLCSettingPlaybackBackwardSkipLengthDefaultValue,
                                  kVLCSettingOpenAppForPlayback : kVLCSettingOpenAppForPlaybackDefaultValue};
    [defaults registerDefaults:appDefaults];
}

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
    BITHockeyManager *hockeyManager = [BITHockeyManager sharedHockeyManager];

    if (BETA_DISTRIBUTION) {
        APLog(@"Using HockeySDK beta key");
        [hockeyManager configureWithIdentifier:@"0114ca8e265244ce588d2ebd035c3577"];
    } else
        [hockeyManager configureWithIdentifier:@"c95f4227dff96c61f8b3a46a25edc584"];

    // Configure the SDK in here only!
    [hockeyManager startManager];
    [hockeyManager.authenticator authenticateInstallation];

    /* listen to validation notification */
    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(passcodeWasValidated:)
                                                 name:VLCPasscodeValidated
                                               object:nil];

    // Change the keyboard for UISearchBar
    [[UITextField appearance] setKeyboardAppearance:UIKeyboardAppearanceDark];
    // For the cursor
    [[UITextField appearance] setTintColor:[UIColor VLCOrangeTintColor]];
    // Don't override the 'Cancel' button color in the search bar with the previous UITextField call. Use the default blue color
    [[UIBarButtonItem appearanceWhenContainedIn:[UISearchBar class], nil] setTitleTextAttributes:@{NSForegroundColorAttributeName: [UIColor colorWithRed:0.0 green:122.0/255.0 blue:1.0 alpha:1.0]} forState:UIControlStateNormal];
    // For the edit selection indicators
    [[UITableView appearance] setTintColor:[UIColor VLCOrangeTintColor]];

    [[UISwitch appearance] setOnTintColor:[UIColor VLCOrangeTintColor]];

    // Init the HTTP Server and clean its cache
    [[VLCHTTPUploaderController sharedInstance] cleanCache];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    // enable crash preventer
    void (^setupBlock)() = ^{
        _playlistViewController = [[VLCPlaylistViewController alloc] init];
        VLCSidebarController *sidebarVC = [VLCSidebarController sharedInstance];
        VLCNavigationController *navCon = [[VLCNavigationController alloc] initWithRootViewController:_playlistViewController];
        sidebarVC.contentViewController = navCon;

        _playerDisplayController = [[VLCPlayerDisplayController alloc] init];
        _playerDisplayController.childViewController = sidebarVC.fullViewController;

        self.window.rootViewController = _playerDisplayController;
        [self.window makeKeyAndVisible];

        [self validatePasscode];

        [[MLMediaLibrary sharedMediaLibrary] applicationWillStart];

        VLCMediaFileDiscoverer *discoverer = [VLCMediaFileDiscoverer sharedInstance];
        [discoverer addObserver:self];
        [discoverer startDiscovering];
    };

    NSError *error = nil;

    if ([[MLMediaLibrary sharedMediaLibrary] libraryMigrationNeeded]){
        _isRunningMigration = YES;

        VLCMigrationViewController *migrationController = [[VLCMigrationViewController alloc] initWithNibName:@"VLCMigrationViewController" bundle:nil];
        migrationController.completionHandler = ^{

            //migrate
            setupBlock();
            _isRunningMigration = NO;
            [[MLMediaLibrary sharedMediaLibrary] updateMediaDatabase];
            [[VLCMediaFileDiscoverer sharedInstance] updateMediaList];
        };

        self.window.rootViewController = migrationController;
        [self.window makeKeyAndVisible];

    } else {
        if (error != nil) {
            APLog(@"removed persistentStore since it was corrupt");
            NSURL *storeURL = ((MLMediaLibrary *)[MLMediaLibrary sharedMediaLibrary]).persistentStoreURL;
            [[NSFileManager defaultManager] removeItemAtURL:storeURL error:&error];
        }
        setupBlock();
    }

    VLCNotificationRelay *notificationRelay = [VLCNotificationRelay sharedRelay];
    [notificationRelay addRelayLocalName:NSManagedObjectContextDidSaveNotification toRemoteName:@"org.videolan.ios-app.dbupdate"];
    [notificationRelay addRelayLocalName:VLCPlaybackControllerPlaybackMetadataDidChange toRemoteName:kVLCDarwinNotificationNowPlayingInfoUpdate];

    return YES;
}

- (void)dealloc
{
    [[NSNotificationCenter defaultCenter] removeObserver:self];
}

#pragma mark - Handoff

- (BOOL)application:(UIApplication *)application willContinueUserActivityWithType:(NSString *)userActivityType
{
    if ([userActivityType isEqualToString:@"org.videolan.vlc-ios.librarymode"] ||
        [userActivityType isEqualToString:@"org.videolan.vlc-ios.playing"] ||
        [userActivityType isEqualToString:@"org.videolan.vlc-ios.libraryselection"])
        return YES;

    return NO;
}

- (BOOL)application:(UIApplication *)application
continueUserActivity:(NSUserActivity *)userActivity
 restorationHandler:(void (^)(NSArray *))restorationHandler
{
    NSString *userActivityType = userActivity.activityType;

    if([userActivityType isEqualToString:@"org.videolan.vlc-ios.librarymode"] ||
       [userActivityType isEqualToString:@"org.videolan.vlc-ios.libraryselection"]) {
        NSDictionary *dict = userActivity.userInfo;
        VLCLibraryMode libraryMode = (VLCLibraryMode)[(NSNumber *)dict[@"state"] integerValue];

        if (libraryMode <= VLCLibraryModeAllSeries) {
            [[VLCSidebarController sharedInstance] selectRowAtIndexPath:[NSIndexPath indexPathForRow:libraryMode inSection:0]
                                                         scrollPosition:UITableViewScrollPositionTop];
            [self.playlistViewController setLibraryMode:(VLCLibraryMode)libraryMode];
        }

        [self.playlistViewController restoreUserActivityState:userActivity];
        _isComingFromHandoff = YES;
        return YES;
    }
    return NO;
}

- (void)application:(UIApplication *)application
didFailToContinueUserActivityWithType:(NSString *)userActivityType
              error:(NSError *)error
{
    if (error.code != NSUserCancelledError){
        //TODO: present alert
    }
}

- (BOOL)application:(UIApplication *)application
            openURL:(NSURL *)url
  sourceApplication:(NSString *)sourceApplication
         annotation:(id)annotation
{
    if ([[DBSession sharedSession] handleOpenURL:url]) {
        [[NSNotificationCenter defaultCenter] postNotificationName:VLCDropboxSessionWasAuthorized object:nil];
        return YES;
    }

    if (_playlistViewController && url != nil) {
        APLog(@"%@ requested %@ to be opened", sourceApplication, url);

        if (url.isFileURL) {
            NSArray *searchPaths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *directoryPath = searchPaths[0];
            NSURL *destinationURL = [NSURL fileURLWithPath:[NSString stringWithFormat:@"%@/%@", directoryPath, url.lastPathComponent]];
            NSError *theError;
            [[NSFileManager defaultManager] moveItemAtURL:url toURL:destinationURL error:&theError];
            if (theError.code != noErr)
                APLog(@"saving the file failed (%li): %@", (long)theError.code, theError.localizedDescription);

            [[VLCMediaFileDiscoverer sharedInstance] updateMediaList];
        } else if ([url.scheme isEqualToString:@"vlc-x-callback"] || [url.host isEqualToString:@"x-callback-url"]) {
            // URL confirmes to the x-callback-url specification
            // vlc-x-callback://x-callback-url/action?param=value&x-success=callback
            APLog(@"x-callback-url with host '%@' path '%@' parameters '%@'", url.host, url.path, url.query);
            NSString *action = [url.path stringByReplacingOccurrencesOfString:@"/" withString:@""];
            NSURL *movieURL;
            NSURL *successCallback;
            NSURL *errorCallback;
            NSString *fileName;
            for (NSString *entry in [url.query componentsSeparatedByString:@"&"]) {
                NSArray *keyvalue = [entry componentsSeparatedByString:@"="];
                if (keyvalue.count < 2) continue;
                NSString *key = keyvalue[0];
                NSString *value = [keyvalue[1] stringByReplacingPercentEscapesUsingEncoding:NSUTF8StringEncoding];

                if ([key isEqualToString:@"url"])
                    movieURL = [NSURL URLWithString:value];
                else if ([key isEqualToString:@"filename"])
                    fileName = value;
                else if ([key isEqualToString:@"x-success"])
                    successCallback = [NSURL URLWithString:value];
                else if ([key isEqualToString:@"x-error"])
                    errorCallback = [NSURL URLWithString:value];
            }
            if ([action isEqualToString:@"stream"] && movieURL) {
                VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
                vpc.fullscreenSessionRequested = YES;
                [vpc playURL:movieURL successCallback:successCallback errorCallback:errorCallback];
            }
            else if ([action isEqualToString:@"download"] && movieURL) {
                [self downloadMovieFromURL:movieURL fileNameOfMedia:fileName];
            }
        } else {
            NSString *receivedUrl = [url absoluteString];
            if ([receivedUrl length] > 6) {
                NSString *verifyVlcUrl = [receivedUrl substringToIndex:6];
                if ([verifyVlcUrl isEqualToString:@"vlc://"]) {
                    NSString *parsedString = [receivedUrl substringFromIndex:6];
                    NSUInteger location = [parsedString rangeOfString:@"//"].location;

                    /* Safari & al mangle vlc://http:// so fix this */
                    if (location != NSNotFound && [parsedString characterAtIndex:location - 1] != 0x3a) { // :
                            parsedString = [NSString stringWithFormat:@"%@://%@", [parsedString substringToIndex:location], [parsedString substringFromIndex:location+2]];
                    } else {
                        parsedString = [receivedUrl substringFromIndex:6];
                        if (![parsedString hasPrefix:@"http://"] && ![parsedString hasPrefix:@"https://"] && ![parsedString hasPrefix:@"ftp://"]) {
                            parsedString = [@"http://" stringByAppendingString:[receivedUrl substringFromIndex:6]];
                        }
                    }
                    url = [NSURL URLWithString:parsedString];
                }
            }
            [[VLCSidebarController sharedInstance] selectRowAtIndexPath:[NSIndexPath indexPathForRow:0 inSection:0]
                                                         scrollPosition:UITableViewScrollPositionNone];

            NSString *scheme = url.scheme;
            if ([scheme isEqualToString:@"http"] || [scheme isEqualToString:@"https"] || [scheme isEqualToString:@"ftp"]) {
                VLCAlertView *alert = [[VLCAlertView alloc] initWithTitle:NSLocalizedString(@"OPEN_STREAM_OR_DOWNLOAD", nil) message:url.absoluteString cancelButtonTitle:NSLocalizedString(@"BUTTON_DOWNLOAD", nil) otherButtonTitles:@[NSLocalizedString(@"PLAY_BUTTON", nil)]];
                alert.completion = ^(BOOL cancelled, NSInteger buttonIndex) {
                    if (cancelled)
                        [self downloadMovieFromURL:url fileNameOfMedia:nil];
                    else {
                        VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
                        [vpc playURL:url successCallback:nil errorCallback:nil];
                    }
                };
                [alert show];
            } else {
                VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
                vpc.fullscreenSessionRequested = YES;
                [vpc playURL:url successCallback:nil errorCallback:nil];
            }
        }
        return YES;
    }
    return NO;
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
    [[MLMediaLibrary sharedMediaLibrary] applicationWillStart];
}

- (void)applicationWillResignActive:(UIApplication *)application
{
    _passcodeValidated = NO;
    [self.playlistViewController setEditing:NO animated:NO];
    [self validatePasscode];
    [[MLMediaLibrary sharedMediaLibrary] applicationWillExit];
}

- (void)applicationDidBecomeActive:(UIApplication *)application
{
    if (!_isRunningMigration && !_isComingFromHandoff) {
        [[MLMediaLibrary sharedMediaLibrary] updateMediaDatabase];
        [[VLCMediaFileDiscoverer sharedInstance] updateMediaList];
    } else if(_isComingFromHandoff) {
        _isComingFromHandoff = NO;
    }
}

- (void)applicationWillTerminate:(UIApplication *)application
{
    _passcodeValidated = NO;
    [[NSUserDefaults standardUserDefaults] synchronize];
}

#pragma mark - media discovering

- (void)mediaFileAdded:(NSString *)fileName loading:(BOOL)isLoading
{
    if (!isLoading) {
        MLMediaLibrary *sharedLibrary = [MLMediaLibrary sharedMediaLibrary];
        [sharedLibrary addFilePaths:@[fileName]];

        /* exclude media files from backup (QA1719) */
        NSURL *excludeURL = [NSURL fileURLWithPath:fileName];
        [excludeURL setResourceValue:@YES forKey:NSURLIsExcludedFromBackupKey error:nil];

        // TODO Should we update media db after adding new files?
        [sharedLibrary updateMediaDatabase];
        [_playlistViewController updateViewContents];
    }
}

- (void)mediaFileDeleted:(NSString *)name
{
    [[MLMediaLibrary sharedMediaLibrary] updateMediaDatabase];
    [_playlistViewController updateViewContents];
}

#pragma mark - pass code validation

- (void)passcodeWasValidated:(NSNotification *)aNotifcation
{
    _passcodeValidated = YES;
    [self.playlistViewController updateViewContents];
    if ([VLCPlaybackController sharedInstance].isPlaying)
        [_playerDisplayController pushPlaybackView];
}

- (BOOL)passcodeValidated
{
    return _passcodeValidated;
}

- (void)validatePasscode
{
    VLCKeychainCoordinator *keychainCoordinator = [VLCKeychainCoordinator defaultCoordinator];

    if (!_passcodeValidated && [keychainCoordinator passcodeLockEnabled]) {
        [_playerDisplayController dismissPlaybackView];

        [keychainCoordinator validatePasscode];
    } else
        _passcodeValidated = YES;
}

#pragma mark - download handling

- (void)downloadMovieFromURL:(NSURL *)url
             fileNameOfMedia:(NSString *)fileName
{
    [[VLCDownloadViewController sharedInstance] addURLToDownloadList:url fileNameOfMedia:fileName];
    [[VLCSidebarController sharedInstance] selectRowAtIndexPath:[NSIndexPath indexPathForRow:2 inSection:1]
                                                 scrollPosition:UITableViewScrollPositionNone];
}

#pragma mark - watch struff
- (void)application:(UIApplication *)application
handleWatchKitExtensionRequest:(NSDictionary *)userInfo
              reply:(void (^)(NSDictionary *))reply
{
    /* dispatch background task */
    __block UIBackgroundTaskIdentifier taskIdentifier = [application beginBackgroundTaskWithName:nil
                                                                               expirationHandler:^{
                                                                                   [application endBackgroundTask:taskIdentifier];
                                                                                   taskIdentifier = UIBackgroundTaskInvalid;
    }];

    VLCWatchMessage *message = [[VLCWatchMessage alloc] initWithDictionary:userInfo];
    NSString *name = message.name;
    NSDictionary *responseDict = nil;
    if ([name isEqualToString:VLCWatchMessageNameGetNowPlayingInfo]) {
        responseDict = [self nowPlayingResponseDict];
    } else if ([name isEqualToString:VLCWatchMessageNamePlayPause]) {
        [[VLCPlaybackController sharedInstance] playPause];
        responseDict = @{@"playing": @([VLCPlaybackController sharedInstance].isPlaying)};
    } else if ([name isEqualToString:VLCWatchMessageNameSkipForward]) {
        [[VLCPlaybackController sharedInstance] forward];
    } else if ([name isEqualToString:VLCWatchMessageNameSkipBackward]) {
        [[VLCPlaybackController sharedInstance] backward];
    } else if ([name isEqualToString:VLCWatchMessageNamePlayFile]) {
        [self playFileFromWatch:message];
    } else if ([name isEqualToString:VLCWatchMessageNameSetVolume]) {
        [self setVolumeFromWatch:message];
    } else {
        APLog(@"Did not handle request from WatchKit Extension: %@",userInfo);
    }
    reply(responseDict);
}

- (void)playFileFromWatch:(VLCWatchMessage *)message
{
    NSManagedObject *managedObject = nil;
    NSString *uriString = (id)message.payload;
    if ([uriString isKindOfClass:[NSString class]]) {
        NSURL *uriRepresentation = [NSURL URLWithString:uriString];
        managedObject = [[MLMediaLibrary sharedMediaLibrary] objectForURIRepresentation:uriRepresentation];
    }
    if (managedObject == nil) {
        APLog(@"%s file not found: %@",__PRETTY_FUNCTION__,message);
        return;
    }

    VLCPlaybackController *vpc = [VLCPlaybackController sharedInstance];
    [vpc playMediaLibraryObject:managedObject];
}

- (void)setVolumeFromWatch:(VLCWatchMessage *)message
{
    NSNumber *volume = (id)message.payload;
    if ([volume isKindOfClass:[NSNumber class]]) {
        /*
         * Since WatchKit doen't provide something like MPVolumeView we use deprecated API.
         * rdar://20783803 Feature Request: WatchKit equivalent for MPVolumeView
         */
        [MPMusicPlayerController applicationMusicPlayer].volume = volume.floatValue;
    }
}

- (NSDictionary *)nowPlayingResponseDict {
    NSMutableDictionary *response = [NSMutableDictionary new];
    NSMutableDictionary *nowPlayingInfo = [[MPNowPlayingInfoCenter defaultCenter].nowPlayingInfo mutableCopy];
    NSNumber *playbackTime = [VLCPlaybackController sharedInstance].mediaPlayer.time.numberValue;
    if (playbackTime) {
        nowPlayingInfo[MPNowPlayingInfoPropertyElapsedPlaybackTime] = @(playbackTime.floatValue/1000);
    }
    if (nowPlayingInfo) {
        response[@"nowPlayingInfo"] = nowPlayingInfo;
    }
    MLFile *currentFile = [VLCPlaybackController sharedInstance].currentlyPlayingMediaFile;
    NSString *URIString = currentFile.objectID.URIRepresentation.absoluteString;
    if (URIString) {
        response[@"URIRepresentation"] = URIString;
    }

    response[@"volume"] = @([MPMusicPlayerController applicationMusicPlayer].volume);

    return response;
}

@end
