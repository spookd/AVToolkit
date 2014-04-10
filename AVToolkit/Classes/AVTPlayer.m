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
@property(nonatomic, assign) BOOL isActive, isReconnecting, isSeeking, shouldResumeWhenReady, shouldRecoverWhenReachable;


@property (strong,nonatomic) AVMediaSelectionGroup *subtitles;
// privat readwrite for public readonly, properties
@property (nonatomic, strong) AVPlayer *player;
@property (strong,nonatomic) NSArray *availableSubtitles;


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
//@synthesize akamaiDelegate, backgroundTask, isActive, isReconnecting, isSeeking, logs, playbackOutputRoute, player, playerLayer, URL, reachability, retryCount, retryLimit, retryPosition, shouldPauseInBackground, shouldPauseWhenRouteChanges, shouldRecoverWhenReachable, shouldResumeWhenReady, state;

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
            }
        }];
    }
}

- (id)init {
    if (self = [super init]) {
        _backgroundTask = UIBackgroundTaskInvalid;
        
        self.retryLimit = 10;
        self.retryCount = 0;
        
        self.isActive       = NO;
        self.isSeeking      = NO;
        self.isReconnecting = NO;
        self.state          = AVTPlayerStateStopped;
        
        self.shouldPauseWhenRouteChanges = YES;
        self.shouldPauseInBackground     = NO;
        self.shouldResumeWhenReady       = NO;
        self.shouldRecoverWhenReachable  = NO;
        
        _playerLayer = [[AVPlayerLayer alloc] init];
        _logs        = NSMutableArray.array;
        
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

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    [self stopWithEndReached:YES settingState:AVTPlayerStateStopped];
    [self teardownPlayer];
}

#pragma mark - UIApplication background handling

- (void)applicationDidEnterBackground {
    if (self.shouldPauseInBackground && self.isPlaying) {
        [self pause];
    } else if (self.state == AVTPlayerStateConnecting || self.state == AVTPlayerStateReconnecting || self.state == AVTPlayerStateSeeking) {
        [self startBackgroundTask];
    }
}

- (void)applicationDidBecomeActive {
    [self endBackgroundTask];
}

#pragma mark - Methods (private): Log

- (void)log:(NSString *)message {
    [self willChangeValueForKey:@"log"]; {
        [self.logs insertObject:message atIndex:0];
        
        if (self.logs.count > 250)
            [self.logs removeLastObject];
    } [self didChangeValueForKey:@"log"];
}

#pragma mark - Methods (private): Player setup & teardown

- (void)setupPlayer {
    [self teardownPlayer];
    
    DBG(@"Setting up player");

    [self willChangeValueForKey:@"player"]; {
        self.player = [[AVPlayer alloc] init];
        self.playerLayer.player = self.player;
        
        if (self.akamaiDelegate && [self.akamaiDelegate respondsToSelector:@selector(player:didSetupPlayer:)]) {
            [self.akamaiDelegate player:self didSetupPlayer:self.player];
        }
        [self.player addObserver:self forKeyPath:@"currentItem" options:observationOptions context:&AVPlayerItemChangedContext];
        [self.player addObserver:self forKeyPath:@"status" options:observationOptions context:&AVPlayerStatusContext];
        [self.player addObserver:self forKeyPath:@"rate" options:observationOptions context:&AVPlayerRateContext];
    } [self didChangeValueForKey:@"player"];
}

- (void)teardownPlayer {
    if (!self.player)
        return;
    
    DBG(@"Tearing down player");
    
    [self willChangeValueForKey:@"player"]; {
        if (self.player.currentItem && ![self.player.currentItem isKindOfClass:NSNull.class]) {
            DBG(@"-- Removing AVPlayerItem observers");
            
            [NSNotificationCenter.defaultCenter removeObserver:self name:AVPlayerItemDidPlayToEndTimeNotification object:self.player.currentItem];
            
            [self.player.currentItem removeObserver:self forKeyPath:@"status" context:&AVPlayerItemStatusContext];
            [self.player.currentItem removeObserver:self forKeyPath:@"playbackBufferEmpty" context:&AVPlayerItemBufferEmptyContext];
            [self.player.currentItem removeObserver:self forKeyPath:@"playbackLikelyToKeepUp" context:&AVPlayerItemLikelyToKeepUpContext];
        }
        
        [self.player removeObserver:self forKeyPath:@"currentItem" context:&AVPlayerItemChangedContext];
        [self.player removeObserver:self forKeyPath:@"status" context:&AVPlayerStatusContext];
        [self.player removeObserver:self forKeyPath:@"rate" context:&AVPlayerRateContext];
        
        if (self.akamaiDelegate && [self.akamaiDelegate respondsToSelector:@selector(player:willReleasePlayer:)]) {
            [self.akamaiDelegate player:self willReleasePlayer:self.player];
        }
        
        self.player = nil;
    } [self didChangeValueForKey:@"player"];
}

#pragma mark - Methods (private): Background task

- (void)startBackgroundTask {
    UIApplicationState appState = UIApplication.sharedApplication.applicationState;
    
    if (appState == UIApplicationStateBackground || appState == UIApplicationStateInactive) {
        if (self.backgroundTask == UIBackgroundTaskInvalid) {
            DBG(@"Invalid background task -- creating a new one");
            
            self.backgroundTask = [UIApplication.sharedApplication beginBackgroundTaskWithExpirationHandler:^{
                dispatch_async(dispatch_get_main_queue(), ^{
                    if (self.backgroundTask != UIBackgroundTaskInvalid) {
                        // Really, if this one got triggered, we're out of luck.
                        // The app will have to be opened (or rmeote controls triggered) in order for us to regain background control ...
                        // Maybe stop playback, throw a "failed to restart" notification? Don't know.
                        
                        DBG(@"Background task killed by the system");
                        [[UIApplication sharedApplication] endBackgroundTask:self.backgroundTask];
                        self.backgroundTask = UIBackgroundTaskInvalid;
                    }
                });
            }];
        }
    }
}

- (void)endBackgroundTask {
    if (self.backgroundTask != UIBackgroundTaskInvalid) {
        [UIApplication.sharedApplication endBackgroundTask:self.backgroundTask];
        self.backgroundTask = UIBackgroundTaskInvalid;
        DBG(@"Background task ended");
    }
}

#pragma mark - Methods (private): Helpers

- (void)reloadPlayerItem {
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(((self.retryCount == 5) ? 2.f : .25f) * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        if (self.URL.isFileURL) {
            [self.player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithAsset:[AVAsset assetWithURL:self.URL]]];
        } else {
            [self.player replaceCurrentItemWithPlayerItem:[AVPlayerItem playerItemWithURL:self.URL]];
        }
    });
}

- (void)resume {
    // TODO: fortæller vi brugeren hvorfor vi fejler?
    if (!self.player || !self.player.currentItem) {
        DBG(@"Tried to resume playback when there isn't a valid player (%@) or item (%@)", self.player, self.player.currentItem);
    }
    
    if (!self.URL.isFileURL && !self.reachability.isReachable) {
        DBG(@"Not a local file and host isn't reachable -- unable to resume");
    }
    
    if (self.player.currentItem.status == AVPlayerItemStatusFailed) {
        [self reloadPlayerItem];
        return;
    }
    
    if (!self.player.currentItem.playbackLikelyToKeepUp)
        return;
    
    if (self.retryPosition != 0) {
        self.position = self.retryPosition;
        self.retryPosition = 0.f;
        return;
    }
    
    [self endBackgroundTask];
    
    if (self.URL.isFileURL && self.player.currentItem.playbackLikelyToKeepUp) {
        self.state  = AVTPlayerStatePlaying;
        
        if (self.player.rate == 0.f)
            self.player.rate = 1.f;
        
        self.retryCount  = 0;
    } else if (!self.URL.isFileURL && self.player.currentItem.playbackLikelyToKeepUp && (self.state == AVTPlayerStateConnecting || self.state == AVTPlayerStateReconnecting || self.state == AVTPlayerStateSeeking)) {
        self.state  = AVTPlayerStatePlaying;
        
        if (self.player.rate == 0.f)
            self.player.rate = 1.f;
        
        self.retryCount  = 0;
    } else {
        self.shouldResumeWhenReady = YES;
    }
}

- (void)stopWithEndReached:(BOOL)endReached settingState:(AVTPlayerState)value {
    self.state = value;
    
    if (!endReached) {
        self.retryPosition = (self.isLiveStream) ? 0.f : self.position;
        self.player.rate   = 0.f;
    } else {
        self.retryPosition = 0.f;
        self.player.rate   = 0.f;
    }
}

#pragma mark - Methods (public): Control

- (void)play {
    self.playbackOutputRoute = AVTAudioSession.sharedInstance.outputRoute;
    
    self.state = (self.isReconnecting) ? AVTPlayerStateReconnecting : AVTPlayerStateConnecting;
    
    [self resume];
}

- (void)pause {
    [self stopWithEndReached:NO settingState:AVTPlayerStatePaused];
}

-(void)changeSubtitlesTo:(NSLocale *)locale{
    __block AVMediaSelectionOption *option;
    [self.subtitles.options enumerateObjectsUsingBlock:^(id obj, NSUInteger idx, BOOL *stop) {
        option = obj;
        if ([option.locale.localeIdentifier isEqualToString:locale.localeIdentifier]) {
            *stop = YES;
        } else {
            option = nil; // if not found then none
        }
    }];
    
    [self.player.currentItem selectMediaOption:option inMediaSelectionGroup:self.subtitles];
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
            if (!self.isPlaying) {
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
        switch (self.player.status) {
            case AVPlayerStatusReadyToPlay:
                DBG(@"Player (Ready)");
                break;
                
            case AVPlayerStatusFailed:
                DBG(@"Player (Failed): %@", self.player.error.description);
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
        switch (self.player.currentItem.status) {
            case AVPlayerItemStatusReadyToPlay: {
                
                // collecting the options from the stream
                // TODO: collect audio
                NSArray *group = [self.player.currentItem.asset availableMediaCharacteristicsWithMediaSelectionOptions];
                
                if ([group containsObject:AVMediaCharacteristicLegible]) {
                    

                    self.subtitles = [self.player.currentItem.asset mediaSelectionGroupForMediaCharacteristic:AVMediaCharacteristicLegible];
                   NSMutableArray *availableSubtitles = [[NSMutableArray alloc]initWithCapacity:self.subtitles.options.count-1];
                    
                    for (AVMediaSelectionOption *subtitleOption in self.subtitles.options) {
                        [availableSubtitles addObject:subtitleOption.locale];
                    }
                    
                    [self willChangeValueForKey:@"availableSubtitles"];
                    self.availableSubtitles  = [NSArray arrayWithArray:availableSubtitles];
                    [self didChangeValueForKey:@"availableSubtitles"];
                }
              
                DBG(@"PlayerItem (Ready)");
                self.retryCount = 0;
                break;
            }
                
            case AVPlayerItemStatusUnknown: {
                DBG(@"PlayerItem (Unknown)");
                break;
            }
                
            case AVPlayerItemStatusFailed: {
                DBG(@"PlayerItem (Failed): %@", self.player.currentItem.error.localizedDescription);
                
                if (self.retryCount++ < self.retryLimit) {
                    if (self.URL.isFileURL || self.reachability.isReachable)
                        [self reloadPlayerItem];
                    else
                        self.shouldRecoverWhenReachable = YES;
                } else {
                    DBG(@"PlayerItem failed %ld times now -- giving up", (long)self.retryLimit);
                    [self pause];
                    [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerFailedToPlayNotification object:nil];
                    self.retryCount = 0;
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
        
        if (!self.isPlaying) {
            self.isReconnecting = YES;
        } else if (!self.URL.isFileURL && !self.isLiveStream && !self.reachability.isReachable) {
            self.shouldRecoverWhenReachable = YES;
        } else {
            self.state = (self.isSeeking) ? AVTPlayerStateSeeking : AVTPlayerStateReconnecting;
        }
        [self startBackgroundTask];
    } else {
        self.isReconnecting = NO;
        DBG(@"PlayerItem buffer not empty anymore");
    }
}

- (void)handlePlayerItemLikelyToKeepUpChanged:(NSDictionary *)change {
    NSUInteger valueChangeKind = [change[NSKeyValueChangeKindKey] integerValue];
    BOOL newValue = [change[NSKeyValueChangeNewKey] boolValue];
    
    if (valueChangeKind == NSKeyValueChangeSetting && newValue) {
        DBG(@"PlayerItem buffer likely to keep up");
        
        self.isSeeking = NO;
        
        if ((self.reachability.isReachable || self.URL.isFileURL) && self.isPlaying) {
            DBG(@"-- Will resume");
            [self resume];
            
            if (self.retryPosition == 0.f)
                return;
            
            // Sometimes, during prolonged disconnectivity, the player wont start playing even though the rate is set to 1.f (and it's buffering)
            // Let's do a check after 1s and re-set the rate if it hasn't started ...
            NSTimeInterval lastPosition = self.position;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1.f * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
                if (lastPosition == self.position && self.isPlaying) {
                    DBG(@"Re-set the position as it didn't start correctly");
                    self.player.rate = 0.f;
                    self.player.rate = 1.f;
                }
            });
        }
        
        [self endBackgroundTask];
    } else {
        DBG(@"PlayerItem buffer not likely to keep up");
    }
}

#pragma mark - Notifications: Audio session

- (void)beginInterruption:(NSNotification *)notification {
    if (self.isPlaying) {
        DBG(@"Interrupted -- pausing");
        [self stopWithEndReached:NO settingState:AVTPlayerStateInterrupted];
    }
}

- (void)endInterruption:(NSNotification *)notification {
    if (self.state == AVTPlayerStateInterrupted) {
        DBG(@"Interruption ended -- resuming");
        [self play];
    }
}

- (void)audioRouteChanged:(NSNotification *)notification {
    if (AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteHeadphones
        && AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteBluetoothHandsfree
        && AVTAudioSession.sharedInstance.outputRoute != AVTAudioSessionOutputRouteAirPlay
        && AVTAudioSession.sharedInstance.outputRoute != self.playbackOutputRoute) {
        if (self.isPlaying && self.shouldPauseWhenRouteChanges) {
            DBG(@"Audio route changed -- pausing");
            [self pause];
        }
    }
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
    self.seekingToTime = CMTimeMakeWithSeconds(position, self.player.currentItem.asset.duration.timescale);
    
    if (self.isPlaying)
        self.state = AVTPlayerStateSeeking;
    
    [self.player.currentItem seekToTime:self.seekingToTime toleranceBefore:kCMTimeZero toleranceAfter:kCMTimeZero];
}

- (NSTimeInterval)position {
    if (self.isSeeking) {
        return CMTimeGetSeconds(self.seekingToTime);
    }
    
    Float64 time = CMTimeGetSeconds([self.player currentTime]);
    
    if (time < 0.f || isnan(time))
        time = 0.f;
    
    return time;
}

- (void)setRate:(float)rate {
    if (self.isLiveStream && rate != 0.f && rate != 1.f) {
        DBG(@"Tried to set rate to %f on a live stream -- you can't do that!", rate);
        return;
    }
    
    self.player.rate = rate;
}

- (float)rate {
    return self.player.rate;
}

-(void)setURL:(NSURL *)URL{
    self.retryPosition = 0.f;
    
    AVPlayerItem *item;
    BOOL isSameHost = (self.reachability && _URL && [_URL.host isEqualToString:URL.host]);
    
    [self stopWithEndReached:YES settingState:AVTPlayerStateStopped];
    
    [self teardownPlayer];
    [self setupPlayer];
    
    [self willChangeValueForKey:@"availableSubtitles"];
    self.availableSubtitles = nil;
    [self didChangeValueForKey:@"availableSubtitles"];
    
    [self willChangeValueForKey:@"URL"];
    _URL = URL;
    [self didChangeValueForKey:@"URL"];
    
    if (URL.isFileURL) {
        // We don't need reachability here
        if (self.reachability) {
            [self.reachability stopNotifier];
            self.reachability = nil;
        }
        
        item = [AVPlayerItem playerItemWithAsset:[AVAsset assetWithURL:_URL]];
    } else {
        item = [AVPlayerItem playerItemWithURL:_URL];
    }
    
    if (!_URL.isFileURL && !isSameHost) {
        // Only allow starting playback if streaming host is reachable
        if (self.reachability) {
            [self.reachability stopNotifier];
            self.reachability = nil;
        }
        
        self.reachability = [Reachability reachabilityWithHostname:_URL.host];
        typeof(self) __weak weakSelf = self;
        
        self.reachability.reachableBlock = ^(Reachability *reach) {
            typeof(weakSelf) __strong strongSelf = weakSelf;
            if (strongSelf->_shouldResumeWhenReady) {
                strongSelf->_shouldResumeWhenReady = NO;
                [strongSelf resume];
            }
            
            if (strongSelf->_shouldRecoverWhenReachable) {
                strongSelf->_shouldRecoverWhenReachable = NO;
                [strongSelf stopWithEndReached:NO settingState:strongSelf.state];
                [strongSelf reloadPlayerItem];
            }
            
            [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerHostReachableNotification object:strongSelf];
        };
        
        self.reachability.unreachableBlock = ^(Reachability *reach) {
            typeof(weakSelf) __strong strongSelf = weakSelf;
            
            [NSNotificationCenter.defaultCenter postNotificationName:AVTPlayerHostUnreachableNotification object:strongSelf];
        };
        
        [self.reachability startNotifier];
    }
    
    [self.player replaceCurrentItemWithPlayerItem:item];
}


- (void)setState:(AVTPlayerState)state {
    if (state == _state)
        return;
    
    [self willChangeValueForKey:@"state"];
    _state = state;
    [self didChangeValueForKey:@"state"];
}

- (BOOL)isPlaying {
    return !(self.state == AVTPlayerStateStopped || self.state == AVTPlayerStatePaused || self.state == AVTPlayerStateInterrupted);
}

#pragma mark - Properties: Readonly

- (NSArray *)log {
    return self.logs.copy; // TODO: hvorfor en copy?
}

- (BOOL)isLiveStream {
    return isnan(self.duration) || self.duration == 0.f;
}

- (NSTimeInterval)duration {
    if (!self.player.currentItem)
        return 0.0f;
    
    return CMTimeGetSeconds([self.player.currentItem duration]);
}

- (NSTimeInterval)bufferedDuration {
    if (self.player.currentItem && self.player.currentItem.loadedTimeRanges.count == 0) {
        return 0.0f;
    }
    
    CMTimeRange timeRange = [self.player.currentItem.loadedTimeRanges[0] CMTimeRangeValue];
    NSTimeInterval result = CMTimeGetSeconds(timeRange.start) + CMTimeGetSeconds(timeRange.duration);
    
    if (isnan(result))
        return 0.f;
    
    return result;
}

@end