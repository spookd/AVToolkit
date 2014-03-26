//
//  AVTPlayerViewController.m
//  AVToolkitExample
//
//  Created by Nicolai Persson on 26/03/14.
//  Copyright (c) 2014 Danish Broadcasting Corporation. All rights reserved.
//

#import "AVTPlayerViewController.h"

#import <AVToolkit/AVToolkit.h>
#import <QuartzCore/QuartzCore.h>

extern void ensure_main_thread(void (^block)(void));

@implementation UIButton (AVTPlayerExample)

- (void)setEnabled:(BOOL)enabled {
    [super setEnabled:enabled];
    
    ensure_main_thread(^{
        self.alpha = (enabled) ? 1.f : .5f;
    });
}

@end

@interface AVTPlayerViewController() <UITextFieldDelegate, UIAlertViewDelegate> {
    UIImage *playImage, *stopImage;
    NSTimer *positionTimer;
    UIAlertView *failedToPlayAlert;
}
@end

@implementation AVTPlayerViewController
@synthesize positionSlider, segmentedControl, statusLabel, textField, textView, toggleButton;

- (id)initWithCoder:(NSCoder *)coder {
    if (self = [super initWithCoder:coder]) {
        // Test URLs
        
        playImage = [UIImage imageNamed:@"icon-play"];
        stopImage = [UIImage imageNamed:@"icon-stop"];
        
        [AVTPlayer.defaultPlayer addObserver:self forKeyPath:@"state" options:NSKeyValueObservingOptionNew context:nil];
        [AVTPlayer.defaultPlayer addObserver:self forKeyPath:@"log" options:NSKeyValueObservingOptionNew context:nil];
        [AVTPlayer.defaultPlayer addObserver:self forKeyPath:@"URL" options:NSKeyValueObservingOptionNew context:nil];
        
        [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(failedToPlayNotification:) name:AVTPlayerFailedToPlayNotification object:nil];
    }
    
    return self;
}

- (void)dealloc {
    [NSNotificationCenter.defaultCenter removeObserver:self];
    
    [AVTPlayer.defaultPlayer removeObserver:self forKeyPath:@"state"];
    [AVTPlayer.defaultPlayer removeObserver:self forKeyPath:@"log"];
    [AVTPlayer.defaultPlayer removeObserver:self forKeyPath:@"URL"];
}

- (void)viewDidLoad {
    [super viewDidLoad];
    
    [self.view.layer insertSublayer:AVTPlayer.defaultPlayer.playerLayer atIndex:0];
    AVTPlayer.defaultPlayer.playerLayer.frame = self.view.bounds;
    
    toggleButton.backgroundColor    = [UIColor colorWithRed:0.0 green:122.0/255.0 blue:1.0 alpha:1.0];
    toggleButton.layer.cornerRadius = 5.f;
    toggleButton.enabled = NO;
    
    textField.delegate = self;
    
    [toggleButton setImage:playImage forState:UIControlStateNormal];
    
    [positionSlider addTarget:self action:@selector(positionValueChanged:event:) forControlEvents:UIControlEventValueChanged];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
}

- (void)viewDidAppear:(BOOL)animated {
    [super viewDidAppear:animated];
    [UIApplication.sharedApplication beginReceivingRemoteControlEvents];
}

- (void)viewWillDisappear:(BOOL)animated {
    [super viewWillDisappear:animated];
    [UIApplication.sharedApplication endReceivingRemoteControlEvents];
}

- (void)remoteControlReceivedWithEvent:(UIEvent *)event {
    [AVTPlayer.defaultPlayer remoteControlReceivedWithEvent:event];
}

- (void)didRotateFromInterfaceOrientation:(UIInterfaceOrientation)fromInterfaceOrientation {
    AVTPlayer.defaultPlayer.playerLayer.frame = self.view.bounds;
}

#pragma mark - Helpers

- (NSString *)stringFromInterval:(NSTimeInterval)timeInterval {
    int secondsPerMinute = 60, minutesPerHour = 60, secondsPerHour = secondsPerMinute * minutesPerHour, hoursPerDay = 24, ti = round(timeInterval);
    
    if ((ti / secondsPerHour) % hoursPerDay > 0)
        return [NSString stringWithFormat:@"%d:%.2d:%.2d", (ti / secondsPerHour) % hoursPerDay, (ti / secondsPerMinute) % minutesPerHour, ti % secondsPerMinute];
    else
        return [NSString stringWithFormat:@"%.2d:%.2d", (ti / secondsPerMinute) % minutesPerHour, ti % secondsPerMinute];
}

- (void)startPositionTimer {
    positionTimer = [NSTimer timerWithTimeInterval:1.0f target:self selector:@selector(refreshSliderPosition) userInfo:nil repeats:YES];
    [NSRunLoop.currentRunLoop addTimer:positionTimer forMode:NSDefaultRunLoopMode];
}

- (void)stopPositionTimer {
    if (positionTimer) {
        [positionTimer invalidate];
        positionTimer = nil;
    }
}

#pragma mark - Actions/Callbacks

- (void)failedToPlayNotification:(NSNotification *)notification {
    if (failedToPlayAlert)
        return;
    
    failedToPlayAlert = [[UIAlertView alloc] initWithTitle:@"Sorry!"
                                                   message:@"Seems there was a problem preparing the stream. Try again."
                                                  delegate:self
                                         cancelButtonTitle:nil
                                         otherButtonTitles:@"OK", nil];
    [failedToPlayAlert show];
}

- (IBAction)togglePressed:(id)sender {
    if (AVTPlayer.defaultPlayer.isStopped)
        [AVTPlayer.defaultPlayer play];
    else
        [AVTPlayer.defaultPlayer pause];
}

- (IBAction)fieldValueChanged:(id)sender {
    AVTPlayer.defaultPlayer.URL = [NSURL URLWithString:textField.text];
}

- (IBAction)presetPressed:(id)sender {
    if (textField.isFirstResponder)
        [textField resignFirstResponder];
    
    switch (segmentedControl.selectedSegmentIndex) {
        case 0:
            textField.text = @"http://drradio3-lh.akamaihd.net/i/p3_9@143506/master.m3u8";
            break;
            
        case 1:
            textField.text = @"http://drod03e-vh.akamaihd.net/i/all/clear/download/44/532866fba11f9d0c6c2a7c44/Monte-Carlo_20a7da2f5c80423da5159782b547a3d7_,192,61,.mp4.csmil/master.m3u8";
            break;
            
        default:
            textField.text = @"http://drod03e-vh.akamaihd.net/p/all/clear/download/44/532866fba11f9d0c6c2a7c44/Monte-Carlo_20a7da2f5c80423da5159782b547a3d7_192.mp4";
            break;
    }
    
    [self fieldValueChanged:sender];
}

- (void)positionValueChanged:(id)sender event:(id)event {
    UITouch *touchEvent = [[event allTouches] anyObject];
    
    if (touchEvent.phase == UITouchPhaseBegan) {
        [self stopPositionTimer];
    } else if (touchEvent.phase == UITouchPhaseEnded) {
        AVTPlayer.defaultPlayer.position = positionSlider.value;
    }
    
    if (AVTPlayer.defaultPlayer.state == AVTPlayerStatePlaying && !AVTPlayer.defaultPlayer.isLiveStream) {
        statusLabel.text = [NSString stringWithFormat:@"Playing (%@)", [self stringFromInterval:positionSlider.value]];
    }
}

- (void)refreshSliderPosition {
    if (AVTPlayer.defaultPlayer.state != AVTPlayerStatePlaying || AVTPlayer.defaultPlayer.isLiveStream)
        return;
    
    positionSlider.minimumValue = 0.f;
    positionSlider.maximumValue = (isnan(AVTPlayer.defaultPlayer.duration)) ? 0.f : AVTPlayer.defaultPlayer.duration;
    positionSlider.value        = AVTPlayer.defaultPlayer.position;
    
    statusLabel.text = [NSString stringWithFormat:@"Playing (%@)", [self stringFromInterval:positionSlider.value]];
}

#pragma mark - Observation

- (NSString *)stateFromPlayer {
    [self stopPositionTimer];
    
    switch (AVTPlayer.defaultPlayer.state) {
        case AVTPlayerStateConnecting:
            return @"Connecting ...";
            
        case AVTPlayerStateInterrupted:
            return @"Interrupted";
            
        case AVTPlayerStatePaused:
            return @"Paused";
            
        case AVTPlayerStatePlaying: {
            if (AVTPlayer.defaultPlayer.state == AVTPlayerStatePlaying && !AVTPlayer.defaultPlayer.isLiveStream) {
                [self startPositionTimer];
                return [NSString stringWithFormat:@"Playing (%@)", [self stringFromInterval:positionSlider.value]];
            } else {
                positionSlider.value = 0.f;
                positionSlider.maximumValue = 0.f;
            }
            return @"Playing";
        }
            
        case AVTPlayerStateReconnecting:
            return @"Reconnecting ...";
            
        case AVTPlayerStateSeeking:
            return @"Seeking ...";
            
        case AVTPlayerStateStopped:
            return @"Stopped";
            
        default:
            return @"-";
    }
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context {
    if ([object isKindOfClass:[AVTPlayer class]]) {
        ensure_main_thread(^{
            if ([keyPath isEqualToString:@"state"]) {
                statusLabel.text = [self stateFromPlayer];
                
                if (AVTPlayer.defaultPlayer.isStopped) {
                    [toggleButton setImage:playImage forState:UIControlStateNormal];
                } else {
                    [toggleButton setImage:stopImage forState:UIControlStateNormal];
                }
            } else if ([keyPath isEqualToString:@"log"]) {
                textView.text = [AVTPlayer.defaultPlayer.log componentsJoinedByString:@"\n\n"];
            } else if ([keyPath isEqualToString:@"URL"]) {
                toggleButton.enabled = (AVTPlayer.defaultPlayer.URL != nil);
            }
        });
    }
}

#pragma mark - UITextFieldDelegate

- (BOOL)textFieldShouldReturn:(UITextField *)field {
    return [field resignFirstResponder];
}

#pragma mark - UIAlertViewDelegate

- (void)alertView:(UIAlertView *)alertView didDismissWithButtonIndex:(NSInteger)buttonIndex {
    failedToPlayAlert = nil;
}

@end
