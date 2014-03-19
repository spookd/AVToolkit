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

// Notifications

#define AVTAudioSessionRouteChanged           @"AVTAudioSessionRouteChanged"
#define AVTAudioSessionMediaServicesReset     @"AVTAudioSessionMediaServicesReset"
#define AVTAudioSessionMediaServicesLost      @"AVTAudioSessionMediaServicesLost"

#define AVTAudioSessionBeginInterruption      @"AVTAudioSessionBeginInterruption"
#define AVTAudioSessionEndInterruption        @"AVTAudioSessionEndInterruption"

#define AVTAudioSessionInputBecameAvailable   @"AVTAudioSessionInputBecameAvailable"
#define AVTAudioSessionInputBecameUnavailable @"AVTAudioSessionInputBecameUnavailable"

#define AVTAudioSessionShouldResume           @"AVTAudioSessionShouldResume"

// Types

typedef NS_ENUM(NSUInteger, AVTAudioSessionOutputRoute) {
    AVTAudioSessionOutputRouteNone, // This would be it in the simulator - or if the session hasn't been initialized correctly
    AVTAudioSessionOutputRouteLineOut,
    AVTAudioSessionOutputRouteHeadphones,
    AVTAudioSessionOutputRouteBluetooth,
    AVTAudioSessionOutputRouteBluetoothHandsfree,
    AVTAudioSessionOutputRouteBuiltInReceiver,
    AVTAudioSessionOutputRouteBuiltInSpeaker,
    AVTAudioSessionOutputRouteUSB,
    AVTAudioSessionOutputRouteHDMI,
    AVTAudioSessionOutputRouteAirPlay
};

typedef NS_ENUM(NSUInteger, AVTAudioSessionInputRoute) {
    AVTAudioSessionInputRouteNone, // This would be it in the simulator - or if the session hasn't been initialized correctly
    AVTAudioSessionInputRouteLineIn,
    AVTAudioSessionInputRouteBuiltInMicrophone,
    AVTAudioSessionInputRouteHeadset,
    AVTAudioSessionInputRouteBluetoothHandsfree,
    AVTAudioSessionInputRouteUSB,
};

typedef NS_ENUM(NSUInteger, AVTAudioSessionRouteChangeReason) {
    AVTAudioSessionRouteChangeReasonUnknown                    = 0,
    AVTAudioSessionRouteChangeReasonNewDeviceAvailable         = 1,
    AVTAudioSessionRouteChangeReasonOldDeviceUnavailable       = 2,
    AVTAudioSessionRouteChangeReasonCategoryChange             = 3,
    AVTAudioSessionRouteChangeReasonOverride                   = 4,
    AVTAudioSessionRouteChangeReasonWakeFromSleep              = 6,
    AVTAudioSessionRouteChangeReasonNoSuitableRouteForCategory = 7
};

typedef void (^AVTAudioSessionMuteCheck)(BOOL activated);
typedef void (^AVTAudioSessionToggleActivation)(BOOL activated, NSError *error);

// ----

@interface AVTAudioSession : NSObject
+ (instancetype)sharedInstance;

- (void)activate:(AVTAudioSessionToggleActivation)completed;
- (void)deactivate:(AVTAudioSessionToggleActivation)completed;

- (void)muteSwitchActivated:(AVTAudioSessionMuteCheck)completed;

@property(nonatomic, readonly) AVTAudioSessionInputRoute inputRoute;
@property(nonatomic, readonly) AVTAudioSessionOutputRoute outputRoute;

@property(nonatomic, readonly) AVTAudioSessionInputRoute inputRoutePrevious;
@property(nonatomic, readonly) AVTAudioSessionOutputRoute outputRoutePrevious;

@property(nonatomic, readonly) AVTAudioSessionRouteChangeReason routeChangeReason;

@property(nonatomic, readonly) BOOL hasActiveCall;
@end
