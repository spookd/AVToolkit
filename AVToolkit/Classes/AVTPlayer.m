//
//  Copyright 2014 Danish Broadcasting Corporation
//
//  Licensed under the Apache License, Version 2.0 (the "License");
//  you may not use this file except in compliance with the License.
//  You may obtain a copy of the License at
//
//      http://www.apache.org/licenses/LICENSE-2.0
//
//  Unless required by applicable law or agreed to in writing, software
//  distributed under the License is distributed on an "AS IS" BASIS,
//  WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
//  See the License for the specific language governing permissions and
//  limitations under the License.
//

#import "AVTPlayer.h"
#import "AVTAudioSession.h"

#import "Reachability.h"

#import <MediaPlayer/MediaPlayer.h>

#ifdef DEBUG
#define DBG(fmt, ...) \
NSLog((@"[DEBUG] %s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__); \
[self log:[NSString stringWithFormat:(@"%s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__, nil]];
#else
#define DBG(fmt, ...) \
[self log:[NSString stringWithFormat:(@"%s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__, nil]];
#endif

#define SET_FLAG(x, y)   (x |= y)
#define UNSET_FLAG(x, y) (x &= ~y)
#define HAS_FLAG(x, y)   ((x & y) == y)

@interface AVTPlayer() {
    UIBackgroundTaskIdentifier backgroundTask;
    AVTAudioSessionOutputRoute playbackOutputRoute;
    
    NSMutableArray *log;
    Reachability   *reachability;
    
    NSUInteger retryCount;
    
    CMTime seekingToTime;
    BOOL isPlaying, isReconnecting, isSeeking, isInterrupted, shouldResumeWhenReachable;
    
}
- (void)log:(NSString *)message;
@end

@implementation AVTPlayer
@synthesize player, playerLayer, state, URL;

static const NSKeyValueObservingOptions observationOptions = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld;

// Contexts: AVPlayer
static const void *AVPlayerStatusContext             = (void *)&AVPlayerStatusContext;
static const void *AVPlayerRateContext               = (void *)&AVPlayerRateContext;
static const void *AVPlayerItemChangedContext        = (void *)&AVPlayerItemChangedContext;
// Contexts: AVPlayerItem
static const void *AVPlayerItemStatusContext         = (void *)&AVPlayerItemStatusContext;
static const void *AVPlayerItemBufferEmptyContext    = (void *)&AVPlayerItemBufferEmptyContext;
static const void *AVPlayerItemLikelyToKeepUpContext = (void *)&AVPlayerItemLikelyToKeepUpContext;

#pragma mark - Singleton

+ (instancetype)defaultPlayer {
    static dispatch_once_t once;
    static id instance;
    
    dispatch_once(&once, ^{
        instance = [[AVTPlayer alloc] initPlayer];
    });
    
    return instance;
}

#pragma mark - Lifecycle

- (id)init {
    self = nil;
    
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Do not initialize this class - use the static method sharedPlayer instead"
                                 userInfo:nil];
    return nil;
}

- (id)initPlayer {
    if (self = [super init]) {
        [self setupPlayer:nil];
        
        log = NSMutableArray.array;
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidEnterBackground)
                                                   name:UIApplicationDidEnterBackgroundNotification
                                                 object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(applicationDidBecomeActive)
                                                   name:UIApplicationDidBecomeActiveNotification
                                                 object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(beginInterruption:)
                                                   name:AVTAudioSessionBeginInterruption
                                                 object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(endInterruption:)
                                                   name:AVTAudioSessionEndInterruption
                                                 object:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:self
                                               selector:@selector(audioRouteChanged:)
                                                   name:AVTAudioSessionRouteChanged
                                                 object:nil];
    }
    
    return self;
}

- (void)dealloc {
    [self stop];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

#pragma mark - Player setup/teardown
- (void)setupPlayer:(AVPlayerItem *)item {
    if (![NSThread.currentThread isEqual:NSThread.mainThread]) {
        dispatch_sync(dispatch_get_main_queue(), ^{
            [self setupPlayer:item];
        });
        
        return;
    }
    
    [self teardownPlayer];
    
    if (item && ![item isKindOfClass:NSNull.class]) {
        DBG(@"-- Adding observers");
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handlePlayerItemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:item];
        [item addObserver:self forKeyPath:@"status" options:observationOptions context:&AVPlayerItemStatusContext];
        [item addObserver:self forKeyPath:@"playbackBufferEmpty" options:observationOptions context:&AVPlayerItemBufferEmptyContext];
        [item addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:observationOptions context:&AVPlayerItemLikelyToKeepUpContext];
    }
    
    player      = (item) ? [[AVPlayer alloc] initWithPlayerItem:item] : [[AVPlayer alloc] init];
    playerLayer = [AVPlayerLayer playerLayerWithPlayer:player];
    
    [player addObserver:self forKeyPath:@"currentItem" options:observationOptions context:&AVPlayerItemChangedContext];
    [player addObserver:self forKeyPath:@"status" options:observationOptions context:&AVPlayerStatusContext];
    [player addObserver:self forKeyPath:@"rate" options:observationOptions context:&AVPlayerRateContext];
}

- (void)teardownPlayer {
    if (!player)
        return;
    
    if (player.currentItem && ![player.currentItem isKindOfClass:NSNull.class]) {
        DBG(@"-- Removing old observers");
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem];
        [player.currentItem removeObserver:self forKeyPath:@"status" context:&AVPlayerItemStatusContext];
        [player.currentItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:&AVPlayerItemBufferEmptyContext];
        [player.currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:&AVPlayerItemLikelyToKeepUpContext];
    }
    
    [player removeObserver:self forKeyPath:@"currentItem" context:&AVPlayerItemChangedContext];
    [player removeObserver:self forKeyPath:@"status" context:&AVPlayerStatusContext];
    [player removeObserver:self forKeyPath:@"rate" context:&AVPlayerRateContext];
    
    player = nil;
}

#pragma mark - Internal

- (void)log:(NSString *)message {
    [log insertObject:message atIndex:0];
    
    if (log.count > 250)
        [log removeLastObject];
}

- (void)reloadPlayerItem {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(.25f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [player replaceCurrentItemWithPlayerItem:nil];
        if (URL.isFileURL) {
            NSLog(@"Reloading local file (%@)", URL);
            AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:URL options:nil];
            NSString *tracksKey = @"tracks";
            [asset loadValuesAsynchronouslyForKeys:@[tracksKey] completionHandler:^{
                NSError *error;
                AVKeyValueStatus status = [asset statusOfValueForKey:tracksKey error:&error];
                
                if (status == AVKeyValueStatusLoaded) {
                    dispatch_async(dispatch_get_main_queue(), ^{
                        [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithAsset:asset]];
                    });
                }
                else {
                    NSLog(@"The asset's tracks were not loaded:\n%@", [error localizedDescription]);
                }
            }];
        } else {
            [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:URL]];
        }
    });
}

- (void)resume {
    if (player.currentItem
        && player.currentItem.playbackLikelyToKeepUp
        && (reachability.isReachable || URL.isFileURL)
        && (state == AVTPlayerStateConnecting || state == AVTPlayerStateReconnecting || state == AVTPlayerStateSeeking || state == AVTPlayerStatePlaying)
        && !isInterrupted) {
        shouldResumeWhenReachable = NO;
        player.rate = 1.f;
        self.state = AVTPlayerStatePlaying;
    } else {
        shouldResumeWhenReachable = YES;
    }
}

#pragma mark - Background task handling

- (void)startBackgroundTask {
    UIApplicationState appState = UIApplication.sharedApplication.applicationState;
    
    if (appState == UIApplicationStateBackground || appState == UIApplicationStateInactive) {
        if (backgroundTask == UIBackgroundTaskInvalid) {
            DBG(@"Invalid background task -- creating a new one");
            backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (backgroundTask != UIBackgroundTaskInvalid) {
                        DBG(@"Background task killed by the system");
                        [[UIApplication sharedApplication] endBackgroundTask:backgroundTask];
                        backgroundTask = UIBackgroundTaskInvalid;
                    }
                });
            }];
        }
    }
}

- (void)endBackgroundTask {
    if (backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:backgroundTask];
        backgroundTask = UIBackgroundTaskInvalid;
    }
}

#pragma mark - Reachability

- (void)setupReachability {
    if (reachability) {
        [reachability stopNotifier];
        reachability = nil;
    }
    
    reachability = [Reachability reachabilityWithHostname:URL.host];
    typeof(self) __weak weakSelf = self;
    
    reachability.reachableBlock = ^(Reachability *reach) {
        typeof(weakSelf) __strong strongSelf = weakSelf;
        if (strongSelf->shouldResumeWhenReachable)
            [strongSelf resume];
        
        [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerHostReachableNotification object:strongSelf];
    };
    
    reachability.unreachableBlock = ^(Reachability *reach) {
        typeof(weakSelf) __strong strongSelf = weakSelf;
    };
    
    [reachability startNotifier];
}

#pragma mark - Playback

- (void)playURL:(NSURL *)value {
    self.URL = value;
    [self play];
}

- (void)play {
    [self stop];
    
    [AVTAudioSession.sharedInstance activate:^(BOOL activated, NSError *error) {
        if (error) {
            DBG(@"Failed to deactivate audio session: %@", error.description);
            [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerFailedToActivateSessionNotification object:self];
            return;
        }
        
        playbackOutputRoute       = AVTAudioSession.sharedInstance.outputRoute;
        shouldResumeWhenReachable = YES;
        isPlaying                 = YES;
        
        self.state = (isReconnecting) ? AVTPlayerStateReconnecting : AVTPlayerStateConnecting;
        
        [self resume];
    }];
}

- (void)pause {
    player.rate = 0.f;
    self.state  = AVTPlayerStatePaused;
}

- (void)stop {
    [player replaceCurrentItemWithPlayerItem:nil];
    player.rate = 0.f;
    
    retryCount = 0;
    
    shouldResumeWhenReachable = NO;
    isSeeking                 = NO;
    isPlaying                 = NO;
    isInterrupted             = NO;
    isReconnecting            = NO;
    
    self.state = AVTPlayerStateStopped;
}

- (BOOL)canBecomeFirstResponder {
    return YES;
}

- (BOOL)becomeFirstResponder {
	return YES;
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPause: {
            [self stop];
            break;
        }
            
        case UIEventSubtypeRemoteControlPlay: {
            [self playURL:self.URL];
            break;
        }
            
        case UIEventSubtypeRemoteControlTogglePlayPause: {
            if (isPlaying) {
                [self stop];
            } else {
                [self playURL:self.URL];
            }
            break;
        }
            
        default:
            break;
    }
}

#pragma mark - Observer

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if (context == &AVPlayerStatusContext) {
        [self handlePlayerStatusChanged:change];
    } else if (context == &AVPlayerRateContext) {
        [self handlePlayerRateChanged:change];
    } else if (context == &AVPlayerItemChangedContext) {
        [self handlePlayerItemChanged:change];
    } else if (context == &AVPlayerItemStatusContext) {
        [self handlePlayerItemStatusChanged:change];
    } else if (context == &AVPlayerItemBufferEmptyContext) {
        [self handlePlayerItemBufferEmptyChanged:change];
    } else if (context == &AVPlayerItemLikelyToKeepUpContext) {
        [self handlePlayerItemLikelyToKeepUpChanged:change];
    }
}

#pragma mark Observer: Handling (AVPlayer)

- (void)handlePlayerStatusChanged:(NSDictionary *)change {
    NSUInteger valueChangeKind = [change[NSKeyValueChangeKindKey] integerValue];
    
    if (valueChangeKind == NSKeyValueChangeSetting && ![change[NSKeyValueChangeNewKey] isEqual:change[NSKeyValueChangeOldKey]]) {
        switch (player.status) {
            case AVPlayerStatusReadyToPlay:
                DBG(@"Player (Ready)");
                break;
                
            case AVPlayerStatusFailed:
                DBG(@"Player (Failed): %@", player.error.description);
                break;
                
            default:
                break;
        }
    }
}

- (void)handlePlayerRateChanged:(NSDictionary *)change {
    float newRate = [change[NSKeyValueChangeNewKey] floatValue];
    float oldRate = [change[NSKeyValueChangeOldKey] floatValue];
    
    if (oldRate == newRate)
        return;
    
    DBG(@"Player rate changed from '%f' to '%f'", oldRate, newRate);
}

- (void)handlePlayerItemChanged:(NSDictionary *)change {
    AVPlayerItem *newItem = change[NSKeyValueChangeNewKey];
    AVPlayerItem *oldItem = change[NSKeyValueChangeOldKey];
    
    DBG(@"PlayerItem changed");
    
    if (oldItem && ![oldItem isKindOfClass:NSNull.class]) {
        DBG(@"-- Removing old observers");
        [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:oldItem];
        [oldItem removeObserver:self forKeyPath:@"status" context:&AVPlayerItemStatusContext];
        [oldItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:&AVPlayerItemBufferEmptyContext];
        [oldItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:&AVPlayerItemLikelyToKeepUpContext];
    }
    
    if (newItem && ![newItem isKindOfClass:NSNull.class]) {
        DBG(@"-- Adding observers");
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(handlePlayerItemDidPlayToEnd:) name:AVPlayerItemDidPlayToEndTimeNotification object:newItem];
        [newItem addObserver:self forKeyPath:@"status" options:observationOptions context:&AVPlayerItemStatusContext];
        [newItem addObserver:self forKeyPath:@"playbackBufferEmpty" options:observationOptions context:&AVPlayerItemBufferEmptyContext];
        [newItem addObserver:self forKeyPath:@"playbackLikelyToKeepUp" options:observationOptions context:&AVPlayerItemLikelyToKeepUpContext];
    }
}

#pragma mark - Observer: Handling (AVPlayerItem)

- (void)handlePlayerItemStatusChanged:(NSDictionary *)change {
    static const NSUInteger retryLimit = 10;
    NSUInteger valueChangeKind = [change[NSKeyValueChangeKindKey] integerValue];
    
    if (valueChangeKind == NSKeyValueChangeSetting && ![change[NSKeyValueChangeNewKey] isEqual:change[NSKeyValueChangeOldKey]]) {
        switch (player.currentItem.status) {
            case AVPlayerItemStatusReadyToPlay: {
                DBG(@"PlayerItem (Ready)");
                retryCount = 0;
                break;
            }
                
            case AVPlayerItemStatusUnknown: {
                DBG(@"PlayerItem (Unknown)");
                break;
            }
                
            case AVPlayerItemStatusFailed: {
                DBG(@"PlayerItem (Failed): %@", player.currentItem.error.localizedDescription);
                
                if (retryCount++ < retryLimit) {
                    [self reloadPlayerItem];
                } else {
                    DBG(@"PlayerItem failed %ld times now -- giving up", (long)retryLimit);
                    [self stop];
                    [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerFailedToPlayNotification object:nil];
                }
                break;
            }
                
            default:
                break;
        }
    }
}

- (void)handlePlayerItemBufferEmptyChanged:(NSDictionary *)change {
    if (change[NSKeyValueChangeNewKey] && [change[NSKeyValueChangeNewKey] boolValue]) {
        if (!isPlaying) {
            isReconnecting = YES;
        } else {
            [self setState:(isSeeking) ? AVTPlayerStateSeeking : AVTPlayerStateReconnecting];
        }
        
        DBG(@"PlayerItem buffer empty");
        [self startBackgroundTask];
        
        if (isPlaying && !reachability.isReachable)
            [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerHostUnreachableNotification object:self];
    } else {
        isReconnecting = NO;
        DBG(@"PlayerItem buffer not empty anymore");
    }
}

- (void)handlePlayerItemLikelyToKeepUpChanged:(NSDictionary *)change {
    NSUInteger valueChangeKind = [change[NSKeyValueChangeKindKey] integerValue];
    BOOL newValue = [change[NSKeyValueChangeNewKey] boolValue];
    
    if (valueChangeKind == NSKeyValueChangeSetting && newValue) {
        DBG(@"PlayerItem buffer likely to keep up");
        
        if ((reachability.isReachable || URL.isFileURL) && isPlaying && !isInterrupted) {
            NSLog(@"Will resume");
            [self resume];
            [self endBackgroundTask];
        }
        
        [self endBackgroundTask];
    } else {
        DBG(@"PlayerItem buffer not likely to keep up");
    }
}

- (void)handlePlayerItemDidPlayToEnd:(NSNotification *)notification {
    [self setState:AVTPlayerStateReachedEnd];
    [self stop];
}

#pragma mark - Notifications: UIApplication

- (void)applicationDidEnterBackground {
    if (state == AVTPlayerStateConnecting || state == AVTPlayerStateReconnecting || state == AVTPlayerStateSeeking)
        [self startBackgroundTask];
}

- (void)applicationDidBecomeActive {
    [self endBackgroundTask];
}

#pragma mark - Notifications: AVTAudioSession

- (void)beginInterruption:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        DBG(@"Interrupted -- incoming call");
        isInterrupted = YES;
        
        if (isPlaying) {
            [self stop];
        }
        
        self.state = AVTPlayerStateInterrupted;
    });
}

- (void)endInterruption:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        DBG(@"Interruption ended");
        isInterrupted = NO;
        
        if (((NSNumber *)notification.userInfo[AVTAudioSessionShouldResume]).boolValue && self.state == AVTPlayerStateInterrupted) {
            [self playURL:self.URL];
        }
    });
}

- (void)audioRouteChanged:(NSNotification *)notification {
    dispatch_async(dispatch_get_main_queue(), ^{
        if (AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteHeadphones
            && AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteBluetoothHandsfree
            && AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteAirPlay
            && AVTAudioSession.sharedInstance.outputRoute != playbackOutputRoute) {
            if (isPlaying) {
                DBG(@"Audio route changed -- pausing");
                [self stop];
                self.state = AVTPlayerStateInterrupted;
            }
            
        }
        
        if (AVTAudioSession.sharedInstance.outputRoute == playbackOutputRoute && self.state == AVTPlayerStateInterrupted) {
            [self playURL:self.URL];
        }
    });
}

#pragma mark - Properties

- (void)setState:(AVTPlayerState)value {
    DBG(@"Set state: %ld", (long)value);
    
    [self willChangeValueForKey:@"state"];
    state = value;
    [self didChangeValueForKey:@"state"];
}

- (void)setURL:(NSURL *)value {
    [self stop];
    
    [reachability stopNotifier];
    
    if (!URL || value.isFileURL != URL.isFileURL) {
        [self setupPlayer:nil];
    }
    
    if (value.isFileURL) {
        URL = value;
        
        DBG(@"Playing local asset: %@", URL);
        
        AVURLAsset *asset = [AVURLAsset URLAssetWithURL:URL options:nil];
        NSString *tracksKey = @"tracks";
        [asset loadValuesAsynchronouslyForKeys:@[tracksKey] completionHandler:^{
             NSError *error;
             AVKeyValueStatus status = [asset statusOfValueForKey:tracksKey error:&error];
             
             if (status == AVKeyValueStatusLoaded) {
                 dispatch_async(dispatch_get_main_queue(), ^{
                     [self setupPlayer:[AVPlayerItem playerItemWithAsset:asset]];
                 });
             }
             else {
                 NSLog(@"The asset's tracks were not loaded:\n%@", [error localizedDescription]);
             }
         }];
    } else {
        BOOL isSameHost = (URL && [URL.host isEqualToString:value.host]);
        
        URL = value;
        dispatch_async(dispatch_get_main_queue(), ^{
            [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:URL]];
        });
        
        if (!isSameHost) {
            [self willChangeValueForKey:@"URL"];
            [self setupReachability];
            [self didChangeValueForKey:@"URL"];
        } else {
            [reachability stopNotifier];
        }
    }
}

- (NSArray *)log {
    return log.copy;
}

#pragma mark - Properties from AVPlayer

- (BOOL)isLiveStream {
    return isnan(self.duration) || self.duration == 0.f;
}

- (NSTimeInterval)duration {
    if (!player.currentItem)
        return 0.0f;
    
    return CMTimeGetSeconds([player.currentItem duration]);
}

- (NSTimeInterval)durationBuffered {
    if (player.currentItem && player.currentItem.loadedTimeRanges.count == 0) {
        DBG(@"Duration available: Nothing valid, returning 0.0");
        return 0.0f;
    }
    
    CMTimeRange timeRange = [player.currentItem.loadedTimeRanges[0] CMTimeRangeValue];
    NSTimeInterval result = CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration);
    
    if (isnan(result))
        return 0.f;
    
    return result;
}

- (void)setPosition:(Float64)value {
    isSeeking     = YES;
    seekingToTime = CMTimeMakeWithSeconds(value, player.currentItem.asset.duration.timescale);;
    
    [player.currentItem seekToTime:seekingToTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (NSTimeInterval)position {
    if (isSeeking) {
        return CMTimeGetSeconds(seekingToTime);
    }
    
    Float64 time = CMTimeGetSeconds([player currentTime]);
    
    if (time < 0.f || isnan(time))
        time = 0.f;
    
    return time;
}

- (void)setRate:(float)value {
    // Live stream? No can do then ...
    if (self.isLiveStream)
        return;
    
    player.rate = value;
}

- (float)rate {
    return player.rate;
}

@end