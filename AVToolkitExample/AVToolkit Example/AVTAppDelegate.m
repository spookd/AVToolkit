//
//  AVTAppDelegate.m
//  AVToolkit Example
//
//  Created by Nicolai Persson on 25/03/14.
//  Copyright (c) 2014 Danish Broadcasting Corporation. All rights reserved.
//

#import "AVTAppDelegate.h"

#import <AVToolkit/AVToolkit.h>

@implementation AVTAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions {
    
    UIStoryboard *storyboard = [UIStoryboard storyboardWithName:@"Storyboard" bundle:nil];

    self.window = [[UIWindow alloc] initWithFrame:[[UIScreen mainScreen] bounds]];
    self.window.backgroundColor    = UIColor.whiteColor;
    self.window.rootViewController = [storyboard instantiateViewControllerWithIdentifier:@"navigationController"];
    [self.window makeKeyAndVisible];
    
    return YES;
}

@end
