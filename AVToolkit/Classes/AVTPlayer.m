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

#import "Reachability.h"
#import "AVTAudioSession.h"

#import <MediaPlayer/MediaPlayer.h>

NSString *AVTPlayerFailedToPlayNotification            = @"AVTPlayerFailedToPlayNotification";
NSString *AVTPlayerFailedToActivateSessionNotification = @"AVTPlayerFailedToPlayNotification";
NSString *AVTPlayerHostReachableNotification           = @"AVTPlayerHostReachable";
NSString *AVTPlayerHostUnreachableNotification         = @"AVTPlayerHostUnreachable";

#ifdef DEBUG
    #define DBG(fmt, ...) \
        NSLog((@"[DEBUG] %s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__); \
        [self log:[NSString stringWithFormat:(@"%s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__, nil]];
#else
    #define DBG(fmt, ...) \
        [self log:[NSString stringWithFormat:(@"%s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__, nil]];
#endif

void ensure_main_thread(void (^block)(void)) {
    if (![NSThread.currentThread isEqual:NSThread.mainThread]) {
        dispatch_sync(dispatch_get_main_queue(), block);
    } else {
        block();
    }
}

void main_queue_async(void (^block)(void)) {
    dispatch_async(dispatch_get_main_queue(), block);
}

NSString *NSStringFromBool(BOOL what) {
    return (what) ? @"Yes" : @"No";
}

@interface AVTPlayer()
@property(nonatomic, strong) NSMutableArray *logs;
@property(nonatomic, strong) Reachability *reachability;
@property(nonatomic, assign) NSTimeInterval retryPosition;
@property(nonatomic, assign) CMTime seekingToTime;
@property(nonatomic, assign) NSInteger retryCount, retryLimit;
@property(nonatomic, assign) UIBackgroundTaskIdentifier backgroundTask;
@property(nonatomic, assign) AVTAudioSessionOutputRoute playbackOutputRoute;
@property(nonatomic, assign) BOOL isActive, isReconnecting, isSeeking, shouldResumeWhenReady;

- (void)log:(NSString *)message;

- (void)setupPlayer;
- (void)teardownPlayer;

- (void)startBackgroundTask;
- (void)endBackgroundTask;

- (void)resume;
- (void)reloadPlayerItem;
- (void)stopWithEndReached:(BOOL)endReached settingState:(AVTPlayerState)state;
@end


@implementation AVTPlayer
@synthesize backgroundTask, isActive, isReconnecting, isSeeking, logs, playbackOutputRoute, player, playerLayer, URL, reachability, retryCount, retryLimit, retryPosition, shouldPauseInBackground, shouldPauseWhenRouteChanges, shouldResumeWhenReady, state;

#pragma mark - Const: KVO observation options

static const NSKeyValueObservingOptions observationOptions = NSKeyValueObservingOptionNew | NSKeyValueObservingOptionOld;

#pragma mark - Const: KVO contexts

static const void *AVPlayerStatusContext             = (void *)&AVPlayerStatusContext;
static const void *AVPlayerRateContext               = (void *)&AVPlayerRateContext;
static const void *AVPlayerItemChangedContext        = (void *)&AVPlayerItemChangedContext;

static const void *AVPlayerItemStatusContext         = (void *)&AVPlayerItemStatusContext;
static const void *AVPlayerItemBufferEmptyContext    = (void *)&AVPlayerItemBufferEmptyContext;
static const void *AVPlayerItemLikelyToKeepUpContext = (void *)&AVPlayerItemLikelyToKeepUpContext;

#pragma mark - Singleton

+ (instancetype)defaultPlayer {
    static dispatch_once_t once;
    static id instance;
    
    dispatch_once(&once, ^{
        instance = [[AVTPlayer alloc] init];
    });
    
    return instance;
}

#pragma mark - Lifecycle

+ (void)initialize {
	if (self == [AVTPlayer class]) {
        [AVTAudioSession.sharedInstance activate:^(BOOL activated, NSError *error) {
            if (error) {
                NSLog(@"!! Failed to activate audio session: %@", error.localizedDescription);
            } else {
                NSLog(@"Audio session activated? %@", (activated) ? @"Yes" : @"No");
            }
        }];
    }
}

- (id)init {
    if (self = [super init]) {
        backgroundTask = UIBackgroundTaskInvalid;
        
        self.retryLimit = 10;
        self.retryCount = 0;
        
        self.isActive       = NO;
        self.isSeeking      = NO;
        self.isReconnecting = NO;
        
        self.shouldPauseWhenRouteChanges = YES;
        self.shouldPauseInBackground     = NO;
        self.shouldResumeWhenReady       = NO;
        
        playerLayer = [[AVPlayerLayer alloc] init];
        state       = AVTPlayerStateStopped;
        logs        = NSMutableArray.array;
        
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
        
        [self setupPlayer];
    }
    
    return self;
}

#pragma mark - UIApplication background handling

- (void)applicationDidEnterBackground {
    if (state == AVTPlayerStateConnecting || state == AVTPlayerStateReconnecting || state == AVTPlayerStateSeeking)
        [self startBackgroundTask];
}

- (void)applicationDidBecomeActive {
    [self endBackgroundTask];
}

#pragma mark - Methods (private): Log

- (void)log:(NSString *)message {
    [self willChangeValueForKey:@"log"]; {
        [logs insertObject:message atIndex:0];
        
        if (logs.count > 250)
            [logs removeLastObject];
    } [self didChangeValueForKey:@"log"];
}

#pragma mark - Methods (private): Player setup & teardown

- (void)setupPlayer {
    [self teardownPlayer];
    
    DBG(@"Setting up player");
    
    ensure_main_thread(^{
        [self willChangeValueForKey:@"player"]; {
            player = [[AVPlayer alloc] init];
            playerLayer.player = player;
            
            [player addObserver:self forKeyPath:@"currentItem" options:observationOptions context:&AVPlayerItemChangedContext];
            [player addObserver:self forKeyPath:@"status" options:observationOptions context:&AVPlayerStatusContext];
            [player addObserver:self forKeyPath:@"rate" options:observationOptions context:&AVPlayerRateContext];
        } [self didChangeValueForKey:@"player"];
    });
}

- (void)teardownPlayer {
    if (!player)
        return;
    
    DBG(@"Tearing down player");
    
    [self willChangeValueForKey:@"player"]; {
        if (player.currentItem && ![player.currentItem isKindOfClass:NSNull.class]) {
            DBG(@"-- Removing AVPlayerItem observers");
            
            [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:player.currentItem];
            
            [player.currentItem removeObserver:self forKeyPath:@"status" context:&AVPlayerItemStatusContext];
            [player.currentItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:&AVPlayerItemBufferEmptyContext];
            [player.currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:&AVPlayerItemLikelyToKeepUpContext];
        }
        
        [player removeObserver:self forKeyPath:@"currentItem" context:&AVPlayerItemChangedContext];
        [player removeObserver:self forKeyPath:@"status" context:&AVPlayerStatusContext];
        [player removeObserver:self forKeyPath:@"rate" context:&AVPlayerRateContext];
        
        
        player = nil;
    } [self didChangeValueForKey:@"player"];
}

#pragma mark - Methods (private): Background task

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
        DBG(@"Background task ended");
    }
}

#pragma mark - Methods (private): Helpers

- (void)reloadPlayerItem {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(((retryCount == 5) ? 2.f : .25f) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (URL.isFileURL) {
            [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithAsset:[AVAsset assetWithURL:URL]]];
        } else {
            [player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:URL]];
        }
    });
}

- (void)resume {
    if (!player || !player.currentItem) {
        DBG(@"Tried to resume playback when there isn't a valid player (%@) or item (%@)", player, player.currentItem);
    }
    
    self.shouldResumeWhenReady = NO;
    
    if (URL.isFileURL && player.currentItem.playbackLikelyToKeepUp) {
        self.state  = AVTPlayerStatePlaying;
        
        if (player.rate == 0.f)
            player.rate = 1.f;
        
        retryCount  = 0;
    } else if (!URL.isFileURL && reachability.isReachable && player.currentItem.playbackLikelyToKeepUp && (self.state == AVTPlayerStateConnecting || self.state == AVTPlayerStateReconnecting || self.state == AVTPlayerStateSeeking)) {
        self.state  = AVTPlayerStatePlaying;
        
        if (player.rate == 0.f)
            player.rate = 1.f;
        
        retryCount  = 0;
    } else {
        self.shouldResumeWhenReady = YES;
        
        DBG(@"Not starting playback:\n"
            "-- URL.isFileURL: %@\n"
            "-- player.currentItem.playbackLikelyToKeepUp: %@\n"
            "-- reachability.isReachable: %@\n"
            "-- self.state(...): %@\n",
            NSStringFromBool(URL.isFileURL),
            NSStringFromBool(player.currentItem.playbackLikelyToKeepUp),
            NSStringFromBool(reachability.isReachable),
            NSStringFromBool(self.state == AVTPlayerStateConnecting || self.state == AVTPlayerStateReconnecting || self.state == AVTPlayerStateSeeking));
    }
}

- (void)stopWithEndReached:(BOOL)endReached settingState:(AVTPlayerState)value {
    self.state = value;
    
    if (!endReached) {
        retryPosition = (self.isLiveStream) ? 0.f : self.position;
        player.rate   = 0.f;
    } else {
        retryPosition = 0.f;
        player.rate   = 0.f;
    }
}

#pragma mark - Methods (public): Control

- (void)play {
    playbackOutputRoute = AVTAudioSession.sharedInstance.outputRoute;
    
    self.state = (self.isReconnecting) ? AVTPlayerStateReconnecting : AVTPlayerStateConnecting;
    
    [self resume];
}

- (void)pause {
    [self stopWithEndReached:NO settingState:AVTPlayerStatePaused];
}

#pragma mark - Methods (public): Remote control event handler

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    switch (event.subtype) {
        case UIEventSubtypeRemoteControlPause: {
            [self pause];
            break;
        }
            
        case UIEventSubtypeRemoteControlPlay: {
            [self play];
            break;
        }
            
        case UIEventSubtypeRemoteControlTogglePlayPause: {
            if (self.isStopped) {
                [self play];
            } else {
                [self pause];
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

#pragma mark - Observer: Handling (AVPlayer)

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
        
        [self resume];
    }
}

#pragma mark - Observer: Handling (AVPlayerItem)

- (void)handlePlayerItemStatusChanged:(NSDictionary *)change {
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
                    [self pause];
                    [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerFailedToPlayNotification object:nil];
                    retryCount = 0;
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
        DBG(@"PlayerItem buffer empty");
        
        if (self.isStopped) {
            isReconnecting = YES;
        } else {
            self.state = (isSeeking) ? AVTPlayerStateSeeking : AVTPlayerStateReconnecting;
        }
        [self startBackgroundTask];
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
        
        isSeeking = NO;
        
        if ((reachability.isReachable || URL.isFileURL) && !self.isStopped) {
            NSLog(@"-- Will resume (%ld)", (long)state);
            [self resume];
        }
        
        [self endBackgroundTask];
    } else {
        DBG(@"PlayerItem buffer not likely to keep up");
    }
}

#pragma mark - Notifications: Audio session

- (void)beginInterruption:(NSNotification *)notification {
    ensure_main_thread(^{
        if (!self.isStopped) {
            DBG(@"Interrupted -- pausing");
            [self stopWithEndReached:NO settingState:AVTPlayerStateInterrupted];
        }
    });
}

- (void)endInterruption:(NSNotification *)notification {
    ensure_main_thread(^{
        if (self.state == AVTPlayerStateInterrupted) {
            DBG(@"Interruption ended -- resuming");
            [self play];
        }
    });
}

- (void)audioRouteChanged:(NSNotification *)notification {
    ensure_main_thread(^{
        if (AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteHeadphones
            && AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteBluetoothHandsfree
            && AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteAirPlay
            && AVTAudioSession.sharedInstance.outputRoute != self.playbackOutputRoute) {
            if (!self.isStopped && self.shouldPauseWhenRouteChanges) {
                DBG(@"Audio route changed -- pausing");
                [self pause];
            }
        }
    });
}

#pragma mark - Notification: Player item

- (void)handlePlayerItemDidPlayToEnd:(NSNotification *)notification {
    [self stopWithEndReached:YES settingState:AVTPlayerStateStopped];
}

#pragma mark - Properties: Read + write

- (void)setPosition:(Float64)position {
    if (self.isLiveStream || position >= self.duration) {
        DBG(@"Cannot seek to %f -- returning", position);
        return;
    }
    
    DBG("Seek to seconds offset: %f", position);
    
    self.isSeeking     = YES;
    self.seekingToTime = CMTimeMakeWithSeconds(position, player.currentItem.asset.duration.timescale);
    self.state         = AVTPlayerStateSeeking;
    
    [player.currentItem seekToTime:self.seekingToTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (NSTimeInterval)position {
    if (isSeeking) {
        return CMTimeGetSeconds(self.seekingToTime);
    }
    
    Float64 time = CMTimeGetSeconds([player currentTime]);
    
    if (time < 0.f || isnan(time))
        time = 0.f;
    
    return time;
}

- (void)setRate:(float)rate {
    if (self.isLiveStream && rate != 0.f && rate != 1.f) {
        DBG(@"Tried to set rate to %f on a live stream -- you can't do that!", rate);
        return;
    }
    
    player.rate = rate;
}

- (float)rate {
    return player.rate;
}

- (void)setURL:(NSURL *)value {
    if (URL && [URL isEqual:value]) {
        DBG(@"Tried to set the same URL already set (%@) -- returning", URL.absoluteString);
        return;
    }
    
    AVPlayerItem *item;
    BOOL isSameHost = (reachability && URL && [URL.host isEqualToString:value.host]);
    
    [self willChangeValueForKey:@"URL"];
    URL = value;
    [self didChangeValueForKey:@"URL"];
    
    [self stopWithEndReached:YES settingState:AVTPlayerStateStopped];
    
    [self teardownPlayer];
    [self setupPlayer];
    
    if (value.isFileURL) {
        // We don't need reachability here
        if (reachability) {
            [reachability stopNotifier];
            reachability = nil;
        }
        
        item = [AVPlayerItem playerItemWithAsset:[AVAsset assetWithURL:URL]];
        
        return;
    } else {
        item = [AVPlayerItem playerItemWithURL:URL];
    }
    
    if (!URL.isFileURL && !isSameHost) {
        // Only allow starting playback if streaming host is reachable
        if (reachability) {
            [reachability stopNotifier];
            reachability = nil;
        }
        
        reachability = [Reachability reachabilityWithHostname:URL.host];
        typeof(self) __weak weakSelf = self;
        
        reachability.reachableBlock = ^(Reachability *reach) {
            typeof(weakSelf) __strong strongSelf = weakSelf;
            if (strongSelf->shouldResumeWhenReady)
                [strongSelf resume];
            
            [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerHostReachableNotification object:strongSelf];
        };
        
        reachability.unreachableBlock = ^(Reachability *reach) {
            typeof(weakSelf) __strong strongSelf = weakSelf;
            
            [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerHostUnreachableNotification object:strongSelf];
        };
        
        [reachability startNotifier];
    }
    
    [player replaceCurrentItemWithPlayerItem:item];
}

- (NSURL *)URL {
    return URL;
}

- (void)setState:(AVTPlayerState)value {
    if (value == state)
        return;
    
    [self willChangeValueForKey:@"state"];
    state = value;
    [self didChangeValueForKey:@"state"];
}

- (BOOL)isStopped {
    return state == AVTPlayerStateStopped || state == AVTPlayerStatePaused || state == AVTPlayerStateInterrupted;
}

#pragma mark - Properties: Readonly

- (NSArray *)log {
    return logs.copy;
}

- (BOOL)isLiveStream {
    return isnan(self.duration) || self.duration == 0.f;
}

- (NSTimeInterval)duration {
    if (!player.currentItem)
        return 0.0f;
    
    return CMTimeGetSeconds([player.currentItem duration]);
}

- (NSTimeInterval)bufferedDuration {
    if (player.currentItem && player.currentItem.loadedTimeRanges.count == 0) {
        return 0.0f;
    }
    
    CMTimeRange timeRange = [player.currentItem.loadedTimeRanges[0] CMTimeRangeValue];
    NSTimeInterval result = CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration);
    
    if (isnan(result))
        return 0.f;
    
    return result;
}

@end