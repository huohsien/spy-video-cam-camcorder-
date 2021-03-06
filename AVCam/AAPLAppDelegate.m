/*
Copyright (C) 2015 Apple Inc. All Rights Reserved.
See LICENSE.txt for this sample’s licensing information

Abstract:
Application delegate.
*/

#import "AAPLAppDelegate.h"

@implementation AAPLAppDelegate

- (BOOL)application:(UIApplication *)application didFinishLaunchingWithOptions:(NSDictionary *)launchOptions
{
	// We use the device orientation to set the video orientation of the video preview,
	// and to set the orientation of still images and recorded videos.

	// Inform the device that we want to use the device orientation.
	[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
    self.window.tintColor = [UIColor colorWithRed:0.01 green:0.41 blue:0.22 alpha:1.0];
    [[UINavigationBar appearance]setTintColor:[UIColor whiteColor]];

	return YES;
}

- (void)applicationWillTerminate:(UIApplication *)application
{
	// Inform the device that we no longer require access the device orientation.
	[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

- (void)applicationWillEnterForeground:(UIApplication *)application
{
	// Inform the device that we want to use the device orientation again.
	[[UIDevice currentDevice] beginGeneratingDeviceOrientationNotifications];
}

- (void)applicationDidEnterBackground:(UIApplication *)application
{
	// Let the device power down the accelerometer if not used elsewhere while backgrounded.
	[[UIDevice currentDevice] endGeneratingDeviceOrientationNotifications];
}

@end
