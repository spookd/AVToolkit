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

#import "AVTAudioSession.h"

#import <AVFoundation/AVFoundation.h>
#import <CoreTelephony/CTCallCenter.h>
#import <CoreTelephony/CTCall.h>

NSString *AVTAudioSessionRouteChanged           = @"AVTAudioSessionRouteChanged";
NSString *AVTAudioSessionMediaServicesReset     = @"AVTAudioSessionMediaServicesReset";
NSString *AVTAudioSessionMediaServicesLost      = @"AVTAudioSessionMediaServicesLost";

NSString *AVTAudioSessionBeginInterruption      = @"AVTAudioSessionBeginInterruption";
NSString *AVTAudioSessionEndInterruption        = @"AVTAudioSessionEndInterruption";

NSString *AVTAudioSessionInputBecameAvailable   = @"AVTAudioSessionInputBecameAvailable";
NSString *AVTAudioSessionInputBecameUnavailable = @"AVTAudioSessionInputBecameUnavailable";

NSString *AVTAudioSessionShouldResume           = @"AVTAudioSessionShouldResume";

#ifdef DEBUG
#define DBG(fmt, ...) \
NSLog((@"[DEBUG] %s (ln %d) " fmt), __PRETTY_FUNCTION__, __LINE__, ##__VA_ARGS__);
#else
#define DBG(fmt, ...)
#endif

#define ENUM_NUMBER(x) [NSNumber numberWithLong:(long)x]

@interface AVTAudioSession() {
    AVTAudioSessionMuteCheck muteCheckCallback;
    NSDate                   *muteCheckStarted;
    SystemSoundID            muteSoundId;
}

- (id)initAudioSession;

- (void)routeChangedWithReason:(SInt32)reason;

- (void)muteSwitchCheckCompleted;
- (void)refreshAudioRoutes;
@end

void AVTAudioSessionMuteCheckCompleted(SystemSoundID ssId, void* clientData) {
    AVTAudioSession *audioSession = (__bridge AVTAudioSession *)clientData;
    [audioSession muteSwitchCheckCompleted];
}

void AVTAudioSessionRouteChangedCallback(void *userData, AudioSessionPropertyID propertyId, UInt32 propertyValueSize, const void *propertyValue) {
    if (propertyId != kAudioSessionProperty_AudioRouteChange)
        return;
    
    SInt32 routeChangeReason;
    
    AVTAudioSession *audioSession = (__bridge AVTAudioSession *)userData;
    
    CFDictionaryRef routeChangeDictionary = propertyValue;
    CFNumberRef routeChangeReasonRef     = CFDictionaryGetValue(routeChangeDictionary, CFSTR(kAudioSession_AudioRouteChangeKey_Reason));
    CFNumberGetValue(routeChangeReasonRef, kCFNumberSInt32Type, &routeChangeReason);
    
    [audioSession routeChangedWithReason:routeChangeReason];
}

// ----

@implementation AVTAudioSession
@synthesize inputRoute, inputRoutePrevious, outputRoute, outputRoutePrevious, routeChangeReason;

#pragma mark Initialization and destruction

+ (instancetype)sharedInstance {
    static dispatch_once_t once;
    static id instance;
    
    dispatch_once(&once, ^{
        instance = [[AVTAudioSession alloc] initAudioSession];
    });
    
    return instance;
}

- (id)init {
    self = nil;
    
    @throw [NSException exceptionWithName:NSInternalInconsistencyException
                                   reason:@"Do not initialize this class - use the static method sharedInstance instead"
                                 userInfo:nil];
    return nil;
}

- (id)initAudioSession {
    if (self = [super init]) {
        NSError *error;
        [[AVAudioSession sharedInstance] setCategory:AVAudioSessionCategoryPlayback error:&error];
        
        if (error) {
            DBG(@"Failed to set audio session category: %@", error.description);
        }
        
        // Set up notifications
        [[NSNotificationCenter defaultCenter] addObserver:self
                                                 selector:@selector(audioSessionInterruption:)
                                                     name:AVAudioSessionInterruptionNotification
                                                   object:AVAudioSession.sharedInstance];
        
        if (error) {
            DBG(@"Failed to initialize audio session: %@", error.description);
        }
        
        //routeChangeReason = AVTAudioSessionRouteChangeReasonUnknown;
        outputRoute       = AVTAudioSessionOutputRouteNone;
        inputRoute        = AVTAudioSessionInputRouteNone;
        
        [self refreshAudioRoutes];
    }
    
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    
    [self deactivate:^(BOOL activated, NSError *error) {
        if (activated) {
            DBG(@"Failed to deactivate audio session: %@", error.description);
        }
    }];
}

#pragma mark Notification helpers

- (void)postInterruptionBegan {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:AVTAudioSessionBeginInterruption
                                                          object:self
                                                        userInfo:nil];
    });
}

- (void)postInterruptionEnded:(BOOL)resume {
    dispatch_async(dispatch_get_main_queue(), ^{
        [NSNotificationCenter.defaultCenter postNotificationName:AVTAudioSessionEndInterruption
                                                          object:self
                                                        userInfo:@{AVTAudioSessionShouldResume: [NSNumber numberWithBool:resume]}];
    });
}

#pragma mark Notifications: AVAudioSession

- (void)routeChangedWithReason:(SInt32)reason {
    routeChangeReason = (int)reason;
    [self refreshAudioRoutes];
}

- (void)audioSessionInterruption:(NSNotification *)notification {
    if ([notification.name isEqualToString:@"AVAudioSessionInterruptionNotification"]) {
        switch ([[notification.userInfo objectForKey:AVAudioSessionInterruptionTypeKey] integerValue]) {
            case AVAudioSessionInterruptionTypeBegan:
                [self postInterruptionBegan];
                break;
                
            case AVAudioSessionInterruptionTypeEnded: {
                NSNumber *resumeKey = [notification.userInfo objectForKey:@"AVAudioSessionInterruptionOptionKey"];
                [self postInterruptionEnded:((resumeKey) ? resumeKey.boolValue : YES)];
                break;
            }
                
            default:
                break;
        }
    } else if ([notification.name isEqualToString:@"AVAudioSessionDidBeginInterruptionNotification"]) {
        [self postInterruptionBegan];
    } else if ([notification.name isEqualToString:@"AVAudioSessionDidEndInterruptionNotification"]) {
        NSNumber *resumeKey = [notification.userInfo objectForKey:@"AVAudioSessionInterruptionOptionKey"];
        [self postInterruptionEnded:((resumeKey) ? resumeKey.boolValue : YES)];
    } else if ([notification.name isEqualToString:@"AVAudioSessionInputDidBecomeAvailableNotification"]) {
        [NSNotificationCenter.defaultCenter postNotificationName:AVTAudioSessionInputBecameAvailable
                                                          object:self
                                                        userInfo:nil];
    } else if ([notification.name isEqualToString:@"AVAudioSessionInputDidBecomeUnavailableNotification"]) {
        [NSNotificationCenter.defaultCenter postNotificationName:AVTAudioSessionInputBecameUnavailable
                                                          object:self
                                                        userInfo:nil];
    }
}

- (void)audioSessionMediaServicesLost:(NSNotification *)notification {
    DBG(@"Services lost: %@", notification.userInfo);
}

- (void)audioSessionMediaServicesReset:(NSNotification *)notification {
    DBG(@"Services reset: %@", notification.userInfo);
}

#pragma mark Session activation/deactivation

- (void)activate:(AVTAudioSessionToggleActivation)completed {
    NSError *error = nil;
    BOOL success   = ([AVAudioSession.sharedInstance setActive:YES error:&error] == YES);
    
    if (success) {
        AudioSessionAddPropertyListener(kAudioSessionProperty_AudioRouteChange,
                                        AVTAudioSessionRouteChangedCallback,
                                        (__bridge void *)self);
    } else {
        DBG(@"Activation failed: %@", error.description);
    }
    
    completed(success, error);
}

- (void)deactivate:(AVTAudioSessionToggleActivation)completed {
    NSError *error = nil;
    BOOL success   = ([AVAudioSession.sharedInstance setActive:NO error:&error] == YES);
    
    if (success) {
        AudioSessionRemovePropertyListenerWithUserData(kAudioSessionProperty_AudioRouteChange,
                                                       AVTAudioSessionRouteChangedCallback,
                                                       (__bridge void *)self);
    } else {
        DBG(@"Deactivation failed: %@", error.description);
    }
    
    completed(success, error);
}

#pragma mark Mute check (inspired by Moshe Gottlieb) -- experimental

- (void)muteSwitchActivated:(AVTAudioSessionMuteCheck)completed {
    if (!completed || muteCheckStarted)
        return;
    
    NSURL *muteSoundFile = nil;
    NSString *bundlePath = [NSBundle.mainBundle pathForResource:@"AVToolkitResources" ofType:@"bundle"];
    
    if (bundlePath) {
        muteSoundFile = [[NSBundle bundleWithPath:bundlePath] URLForResource:@"AVTAudioSessionMuteCheck" withExtension:@"caf"];
    } else {
        DBG(@"AVToolkitResources.bundle not found -- did you forget to include it?");
    }
    
    if (AudioServicesCreateSystemSoundID((__bridge CFURLRef)muteSoundFile, &muteSoundId) == kAudioServicesNoError) {
        muteCheckCallback = completed;
        UInt32 yes        = 1;
        
        AudioServicesAddSystemSoundCompletion(muteSoundId,
                                              CFRunLoopGetMain(),
                                              kCFRunLoopDefaultMode,
                                              AVTAudioSessionMuteCheckCompleted,
                                              (__bridge void *)self);
        
        AudioServicesSetProperty(kAudioServicesPropertyIsUISound, sizeof(muteSoundId), &muteSoundId, sizeof(yes), &yes);
        muteCheckStarted = NSDate.date;
        AudioServicesPlaySystemSound(muteSoundId);
    } else {
        DBG(@"Failed to create system sound -- reporting mute switch activated");
        completed(YES); // I know, I know ...
    }
}

- (void)muteSwitchCheckCompleted {
    AudioServicesRemoveSystemSoundCompletion(muteSoundId);
    AudioServicesDisposeSystemSoundID(muteSoundId);
    
    if (muteCheckStarted && muteCheckCallback) {
        NSTimeInterval interval = [NSDate.date timeIntervalSinceDate:muteCheckStarted];
        DBG(@"Interval: %f", interval);
        muteCheckCallback((interval < .1f));
    }
    
    muteCheckStarted  = nil;
    muteCheckCallback = nil;
}

#pragma mark Audio route

- (void)refreshAudioRoutes {
    outputRoutePrevious = outputRoute;
    inputRoutePrevious  = inputRoute;
    
#if TARGET_IPHONE_SIMULATOR
    outputRoute = AVTAudioSessionOutputRouteBuiltInSpeaker;
    inputRoute  = AVTAudioSessionInputRouteBuiltInMicrophone;
#else
    outputRoute = AVTAudioSessionOutputRouteNone;
    inputRoute  = AVTAudioSessionInputRouteNone;

    CFDictionaryRef dictionary;
    UInt32 dictSize;
    
    AudioSessionGetPropertySize(kAudioSessionProperty_AudioRouteDescription, &dictSize);
    AudioSessionGetProperty(kAudioSessionProperty_AudioRouteDescription, &dictSize, &dictionary);
    
    if (dictionary) {
        CFArrayRef outputs = CFDictionaryGetValue(dictionary, kAudioSession_AudioRouteKey_Outputs);
        CFArrayRef inputs  = CFDictionaryGetValue(dictionary, kAudioSession_AudioRouteKey_Inputs);
        
        // Output
        if (outputs) {
            if (CFArrayGetCount(outputs) > 0) {
                CFDictionaryRef currentOutput = CFArrayGetValueAtIndex(outputs, 0);
                CFStringRef outputType        = CFDictionaryGetValue(currentOutput, kAudioSession_AudioRouteKey_Type);
                
                if (CFStringCompare(outputType, kAudioSessionOutputRoute_LineOut, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteLineOut;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_Headphones, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteHeadphones;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_BluetoothA2DP, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteBluetooth;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_BluetoothHFP, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteBluetoothHandsfree;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_BuiltInReceiver, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteBuiltInReceiver;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_BuiltInSpeaker, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteBuiltInSpeaker;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_BuiltInReceiver, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteBuiltInReceiver;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_USBAudio, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteUSB;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_HDMI, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteHDMI;
                } else if (CFStringCompare(outputType, kAudioSessionOutputRoute_AirPlay, 0) == kCFCompareEqualTo) {
                    outputRoute = AVTAudioSessionOutputRouteAirPlay;
                }
            }
        }
        
        // Input
        if (inputs) {
            if (CFArrayGetCount(inputs) > 0) {
                CFDictionaryRef currentInput = CFArrayGetValueAtIndex(inputs, 0);
                CFStringRef inputType        = CFDictionaryGetValue(currentInput, kAudioSession_AudioRouteKey_Type);
                
                if (CFStringCompare(inputType, kAudioSessionInputRoute_LineIn, 0) == kCFCompareEqualTo) {
                    inputRoute = AVTAudioSessionInputRouteLineIn;
                } else if (CFStringCompare(inputType, kAudioSessionInputRoute_BuiltInMic, 0) == kCFCompareEqualTo) {
                    inputRoute = AVTAudioSessionInputRouteBuiltInMicrophone;
                } else if (CFStringCompare(inputType, kAudioSessionInputRoute_HeadsetMic, 0) == kCFCompareEqualTo) {
                    inputRoute = AVTAudioSessionInputRouteHeadset;
                } else if (CFStringCompare(inputType, kAudioSessionInputRoute_BluetoothHFP, 0) == kCFCompareEqualTo) {
                    inputRoute = AVTAudioSessionInputRouteBluetoothHandsfree;
                } else if (CFStringCompare(inputType, kAudioSessionInputRoute_USBAudio, 0) == kCFCompareEqualTo) {
                    inputRoute = AVTAudioSessionInputRouteUSB;
                }
            }
        }
    } else {
        DBG(@"Dictionary invalid (size reported: %u)", dictSize);
    }
#endif
    
    if (inputRoute != inputRoutePrevious || outputRoute != outputRoutePrevious) {
        [NSNotificationCenter.defaultCenter postNotificationName:AVTAudioSessionRouteChanged
                                                          object:self
                                                        userInfo:@{
                                                                   @"InputRoute":          ENUM_NUMBER(inputRoute),
                                                                   @"InputRoutePrevious":  ENUM_NUMBER(inputRoutePrevious),
                                                                   @"OutputRoute":         ENUM_NUMBER(outputRoute),
                                                                   @"OutputRoutePrevious": ENUM_NUMBER(outputRoutePrevious),
                                                                   @"Reason":              ENUM_NUMBER(routeChangeReason)
                                                                   }];
        
        DBG(@"Audio route changed:")
        DBG(@"-- Input route: %d (previous: %d)", (int)inputRoute, (int)inputRoutePrevious);
        DBG(@"-- Output route: %d (previous: %d)", (int)outputRoute, (int)outputRoutePrevious);
    }
}

#pragma mark Getters

- (AVTAudioSessionInputRoute)inputRoute {
    return inputRoute;
}

- (AVTAudioSessionInputRoute)inputRoutePrevious {
    return inputRoutePrevious;
}

- (AVTAudioSessionOutputRoute)outputRoute {
    return outputRoute;
}

- (AVTAudioSessionOutputRoute)outputRoutePrevious {
    return outputRoutePrevious;
}

- (AVTAudioSessionRouteChangeReason)routeChangeReason {
    return routeChangeReason;
}

- (BOOL)hasActiveCall {
    CTCallCenter *callCenter = [[CTCallCenter alloc] init];
    for (CTCall *call in callCenter.currentCalls)  {
        NSLog(@"Call state: %@", call.callState);
        if (call.callState == CTCallStateConnected) {
            return YES;
        }
    }
    
    return NO;
}

@end
