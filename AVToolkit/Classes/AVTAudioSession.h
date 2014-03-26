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


extern NSString *AVTAudioSessionRouteChanged;
extern NSString *AVTAudioSessionMediaServicesReset;
extern NSString *AVTAudioSessionMediaServicesLost;

extern NSString *AVTAudioSessionBeginInterruption;
extern NSString *AVTAudioSessionEndInterruption;

extern NSString *AVTAudioSessionInputBecameAvailable;
extern NSString *AVTAudioSessionInputBecameUnavailable;

extern NSString *AVTAudioSessionShouldResume;

/**
 Constants that represent the output route of the session
 */
typedef NS_ENUM(NSUInteger, AVTAudioSessionOutputRoute) {
    /** Currently in the simulator, or the session wasn't initialized properly. */
    AVTAudioSessionOutputRouteNone,
    /** Analog line-level output. **/
    AVTAudioSessionOutputRouteLineOut,
    /** Speakers in headphones or in a headset. */
    AVTAudioSessionOutputRouteHeadphones,
    /** Speakers in a Bluetooth A2DP device. */
    AVTAudioSessionOutputRouteBluetooth,
    /** Speakers that are part of a Bluetooth Hands-Free Profile (HFP) accessory. */
    AVTAudioSessionOutputRouteBluetoothHandsfree,
    /** The built-in speaker you hold to your ear when on a phone call. */
    AVTAudioSessionOutputRouteBuiltInReceiver,
    /** The primary built-in speaker. */
    AVTAudioSessionOutputRouteBuiltInSpeaker,
    /** Speaker(s) in a Universal Serial Bus (USB) accessory, accessed through the device 30-pin connector. */
    AVTAudioSessionOutputRouteUSB,
    /** An output available through the HDMI interface. */
    AVTAudioSessionOutputRouteHDMI,
    /** An output on an AirPlay device. */
    AVTAudioSessionOutputRouteAirPlay
};

/**
 Constants that represent the input route of the session
 */
typedef NS_ENUM(NSUInteger, AVTAudioSessionInputRoute) {
    /** Currently in the simulator, or the session wasn't initialized properly. */
    AVTAudioSessionInputRouteNone,
    /** A line in input. */
    AVTAudioSessionInputRouteLineIn,
    /** A built-in microphone input. Some early iOS devices do not have this input. */
    AVTAudioSessionInputRouteBuiltInMicrophone,
    /** A microphone that is part of a headset. */
    AVTAudioSessionInputRouteHeadset,
    /** A microphone that is part of a Bluetooth Hands-Free Profile (HFP) device. */
    AVTAudioSessionInputRouteBluetoothHandsfree,
    /** A Universal Serial Bus (USB) input, accessed through the device 30-pin connector. */
    AVTAudioSessionInputRouteUSB
};

/**
 Constants that represent the reason for the route being changed
 */
typedef NS_ENUM(NSUInteger, AVTAudioSessionRouteChangeReason) {
    /** The audio route changed but the reason is not known. */
    AVTAudioSessionRouteChangeReasonUnknown                    = 0,
    /** A new audio hardware device became available; for example, a headset was plugged in. */
    AVTAudioSessionRouteChangeReasonNewDeviceAvailable         = 1,
    /** The previously-used audio hardware device is now unavailable; for example, a headset was unplugged. */
    AVTAudioSessionRouteChangeReasonOldDeviceUnavailable       = 2,
    /** The audio session category has changed. */
    AVTAudioSessionRouteChangeReasonCategoryChange             = 3,
    /** The audio route has been overridden. */
    AVTAudioSessionRouteChangeReasonOverride                   = 4,
    /** The device woke from sleep. */
    AVTAudioSessionRouteChangeReasonWakeFromSleep              = 6,
    /** There is no audio hardware route for the audio session category. */
    AVTAudioSessionRouteChangeReasonNoSuitableRouteForCategory = 7
};

typedef void (^AVTAudioSessionMuteCheck)(BOOL activated);
typedef void (^AVTAudioSessionToggleActivation)(BOOL activated, NSError *error);

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
