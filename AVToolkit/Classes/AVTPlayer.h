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

@import AVFoundation;
@import UIKit;

@class AVTPlayer;

@protocol AVTPlayerAkamaiSupportDelegate <NSObject>
- (void)player:(AVTPlayer *)player willReleasePlayer:(AVPlayer *)avPlayer;
- (void)player:(AVTPlayer *)player didSetupPlayer:(AVPlayer *)avPlayer;
@end

/**
 Notification thrown when the item failed to load more than 10 times, while the host was reachable.
 */
extern NSString *AVTPlayerFailedToPlayNotification;
/**
 Notification thrown when the audio session activation request was denied for some reason.
 */
extern NSString *AVTPlayerFailedToActivateSessionNotification;
/**
 Notification thrown when the host of the current URL is reachable.
 */
extern NSString *AVTPlayerHostReachableNotification;
/**
 Notification thrown when the host of the current URL isn't reachable.
 */
extern NSString *AVTPlayerHostUnreachableNotification;

/**
 Constants that represent the status of the player.
 */
typedef NS_ENUM(NSUInteger, AVTPlayerState) {
    /** Connecting/firing up the engines */
    AVTPlayerStateConnecting,
    /** Reconnecting due to connection or stream issues */
    AVTPlayerStateReconnecting,
    /** Playback has started */
    AVTPlayerStatePlaying,
    /** Stopped, without reaching the end -- we'll restore the position once started again */
    AVTPlayerStatePaused,
    /** Currently stopped (livestream) or we've reached the end of the current item with a finite duration */
    AVTPlayerStateStopped,
    /** Currently stopped (livestream) or we've reached the end of the current item with a finite duration */
    AVTPlayerStateStoppedEndReached,
    /** Seeking to a specific position on our stream */
    AVTPlayerStateSeeking,
    /** Interrupted by an incoming call, another app smashing ours .. or something like that  */
    AVTPlayerStateInterrupted
};

/**
 A simple class making it easier to work with audio and video on iOS 6 (or later), without having to deal with reachability, reconnections, failed items, etc.
 
 To handle failures and such, you should look into these notifications:
 
 * **AVTPlayerFailedToPlayNotification**
   
   Posted when the item failed to load more than 10 times, while the host was reachable.
 
 * **AVTPlayerFailedToActivateSessionNotification**
 
   Posted when the audio session activation request was denied for some reason. The `userInfo` dictionary contains the key `error` containing the resulting NSError.
 
 * **AVTPlayerHostReachableNotification**
 
   Posted when the host of the current URL is reachable.
 
 * **AVTPlayerHostUnreachableNotification**
 
   Posted when the host of the current URL isn't reachable.
 
 */
@interface AVTPlayer : NSObject
#pragma mark - Creating and using a player
/** @name Creating and Using a Player */
/**
 Singleton support. Yeah.
 */
+ (instancetype)defaultPlayer;

#pragma mark - Managing Playback
/** @name Managing Playback */
/**
 Start playback.
 */
- (void)play;
/**
 Pause playback.
 */
- (void)pause;

/**
 Current URL.
 
 @warning You cannot set the URL to be the same as the current one (call will return).
 @note Successfully setting this will stop any playback there might be.
 @note KVO compliant.
 */
@property(nonatomic, strong) NSURL *URL;
/**
 Current playback position.
 */
@property(nonatomic, readwrite) NSTimeInterval position;
/**
 Current playback rate.
 */
@property(nonatomic, readwrite) float rate;

#pragma mark - Remote Control Handling (i.e. headsets)
/** @name Remote Control Handling (i.e. headsets) */
/**
 If you want remote controls, you should pass the remote control event to this method.
 
 @param event The event passed in the original remoteControlReceivedWithEvent: called.
 */
- (void)remoteControlReceivedWithEvent:(UIEvent *)event;

#pragma mark - Delegates
/**
 Mostly to support Akamai statistics. May be useful for other libraries, too.
 */
@property(nonatomic, weak) id<AVTPlayerAkamaiSupportDelegate> akamaiDelegate;

#pragma mark - Player Properties
/** @name Player Properties */
/**
 The AVPlayer instance used by the player. This is here as some statistics providers require the AVPlayer pointer (i.e. Akamai).
 
 @note KVO compliant.
 */
@property(nonatomic, readonly) AVPlayer *player;
/**
 If you're making a video player, add this layer as a sublayer.
 */
@property(nonatomic, readonly) AVPlayerLayer *playerLayer;
/**
 Whether the current stream is a live stream, or a stream with a finite duration.
 */
@property(nonatomic, readonly) BOOL isLiveStream;
/**
 Used to determine whether the player is actively doing something (i.e. play/pause/stop buttons and such).
 */
@property(nonatomic, readonly) BOOL isPlaying;
/**
 Total duration of the current stream.
 
 @note Will always return 0 for live streams.
 */
@property(nonatomic, readonly) NSTimeInterval duration;
/**
 Total duration buffered so far.
 */
@property(nonatomic, readonly) NSTimeInterval bufferedDuration;
/**
 Current state of the player.
 
 @see AVTPlayerState
 @note KVO compliant.
 */
@property(nonatomic, readonly) AVTPlayerState state;
/**
 Whether or not the player should pause playback when the application enters the background.
 */
@property(nonatomic, assign) BOOL shouldPauseInBackground;
/**
 Whether or not the player should pause playback if the audio route changes.
 */
@property(nonatomic, assign) BOOL shouldPauseWhenRouteChanges;
/**
 Latest 250 debug messages logged.
 */
@property(nonatomic, readonly) NSArray *log;
/**
 An array of AVMediaSelectionOption available in the current stream.
 
 @note KVO complaint.
 */
@property(readonly, nonatomic) NSArray *availableSubtitles;
/**
 Set active subtitle. If nil, subtitles will be disabled.
 */
@property(nonatomic, readwrite) AVMediaSelectionOption *subtitle;
@end
