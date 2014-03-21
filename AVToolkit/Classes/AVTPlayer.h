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

#import <AVFoundation/AVFoundation.h>

#define AVTPlayerFailedToPlayNotification             @"AVTPlayerFailedToPlayNotification"
#define AVTPlayerFailedToActivateSessionNotification  @"AVTPlayerFailedToPlayNotification"
#define AVTPlayerHostReachableNotification            @"AVTPlayerHostReachable"
#define AVTPlayerHostUnreachableNotification          @"AVTPlayerHostUnreachable"

typedef NS_ENUM(NSUInteger, AVTPlayerState) {
    // Connection
    AVTPlayerStateConnecting,
    AVTPlayerStateReconnecting,
    AVTPlayerStateBuffering,
    // Playback
    AVTPlayerStatePlaying,
    AVTPlayerStatePaused,
    AVTPlayerStateStopped,
    AVTPlayerStateSeeking,
    AVTPlayerStateInterrupted,
    AVTPlayerStateReachedEnd,
    // EOL
    AVTPlayerStateCount
};

@interface AVTPlayer : UIResponder

+ (instancetype)defaultPlayer;

- (void)playURL:(NSURL *)URL;
- (void)play;
- (void)stop;

@property(nonatomic, readonly) NSArray *log;
@property(nonatomic, strong) NSURL *URL;

@property(nonatomic, readonly) AVPlayer *player;
@property(nonatomic, readonly) AVPlayerLayer *playerLayer;

@property(nonatomic, readonly) AVTPlayerState state;

@property(nonatomic, readonly) BOOL isLiveStream;
@property(nonatomic, readonly) NSTimeInterval durationBuffered, duration;
@property(nonatomic, readwrite) NSTimeInterval position;
@property(nonatomic, readwrite) float rate;
@end
