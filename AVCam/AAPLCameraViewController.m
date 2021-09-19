/*
Copyright (C) 2015 Apple Inc. All Rights Reserved.
See LICENSE.txt for this sample’s licensing information

Abstract:
View controller for camera interface.
*/

@import AVFoundation;
@import Photos;

#import "AAPLCameraViewController.h"

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningContext = &SessionRunningContext;

typedef NS_ENUM( NSInteger, AVCamSetupResult ) {
	AVCamSetupResultSuccess,
	AVCamSetupResultCameraNotAuthorized,
	AVCamSetupResultSessionConfigurationFailed
};

@interface UINavigationController(custom)
@end
@implementation UINavigationController(custom)
-(UIViewController *)childViewControllerForHomeIndicatorAutoHidden{
    return [self.storyboard  instantiateViewControllerWithIdentifier:@"AAPLCameraViewController"];
}
@end

@interface AAPLCameraViewController () <AVCaptureFileOutputRecordingDelegate, AVCaptureVideoDataOutputSampleBufferDelegate>

// For use in the storyboards.
@property (nonatomic, weak) IBOutlet AAPLPreviewView *previewView;

// Session management.
@property (nonatomic) dispatch_queue_t sessionQueue;
@property (nonatomic) AVCaptureSession *session;
@property (nonatomic) AVCaptureDeviceInput *videoDeviceInput;
@property (nonatomic) AVCaptureMovieFileOutput *movieFileOutput;
@property (nonatomic) AVCaptureStillImageOutput *stillImageOutput;

// Utilities.
@property (nonatomic) AVCamSetupResult setupResult;
@property (nonatomic, getter=isSessionRunning) BOOL sessionRunning;
@property (nonatomic) UIBackgroundTaskIdentifier backgroundRecordingID;

@end

@implementation AAPLCameraViewController {
    
    CGFloat lastTouchedPointX;
    CGFloat lastTouchedPointY;
    CFTimeInterval startTime;
    CFTimeInterval elapsedTime;
    int tapCounter;
    int callTime;
    float horizontalSwipeFactor;
    float zoomFactor;
    float previousZoomFactor;
    float opticalZoomFactor;
}

- (void)viewDidLoad
{
	[super viewDidLoad];

    [[NSNotificationCenter defaultCenter] addObserver:self
                                             selector:@selector(applicationEnteredForeground:)
                                                 name:UIApplicationWillEnterForegroundNotification
                                               object:nil];
    
//    UIImage *_maskingImage = [UIImage imageNamed:@"mask"];
//    CALayer *_maskingLayer = [CALayer layer];
//    _maskingLayer.frame = CGRectMake(0, 0, 34, 60);//self.previewView.bounds;
//    [_maskingLayer setContents:(id)[_maskingImage CGImage]];
//    [self.previewView.layer setMask:_maskingLayer];
    
//	// Disable UI. The UI is enabled if and only if the session starts running.
//	self.cameraButton.enabled = NO;
//	self.recordButton.enabled = NO;
//	self.stillButton.enabled = NO;

	// Create the AVCaptureSession.
	self.session = [[AVCaptureSession alloc] init];

	// Setup the preview view.
	self.previewView.session = self.session;

	// Communicate with the session and other session objects on this queue.
	self.sessionQueue = dispatch_queue_create( "session queue", DISPATCH_QUEUE_SERIAL );

	self.setupResult = AVCamSetupResultSuccess;

	// Check video authorization status. Video access is required and audio access is optional.
	// If audio access is denied, audio is not recorded during movie recording.
	switch ( [AVCaptureDevice authorizationStatusForMediaType:AVMediaTypeVideo] )
	{
		case AVAuthorizationStatusAuthorized:
		{
			// The user has previously granted access to the camera.
			break;
		}
		case AVAuthorizationStatusNotDetermined:
		{
			// The user has not yet been presented with the option to grant video access.
			// We suspend the session queue to delay session setup until the access request has completed to avoid
			// asking the user for audio access if video access is denied.
			// Note that audio access will be implicitly requested when we create an AVCaptureDeviceInput for audio during session setup.
			dispatch_suspend( self.sessionQueue );
			[AVCaptureDevice requestAccessForMediaType:AVMediaTypeVideo completionHandler:^( BOOL granted ) {
				if ( ! granted ) {
					self.setupResult = AVCamSetupResultCameraNotAuthorized;
				}
				dispatch_resume( self.sessionQueue );
			}];
			break;
		}
		default:
		{
			// The user has previously denied access.
			self.setupResult = AVCamSetupResultCameraNotAuthorized;
			break;
		}
	}

	// Setup the capture session.
	// In general it is not safe to mutate an AVCaptureSession or any of its inputs, outputs, or connections from multiple threads at the same time.
	// Why not do all of this on the main queue?
	// Because -[AVCaptureSession startRunning] is a blocking call which can take a long time. We dispatch session setup to the sessionQueue
	// so that the main queue isn't blocked, which keeps the UI responsive.
	dispatch_async( self.sessionQueue, ^{
		if ( self.setupResult != AVCamSetupResultSuccess ) {
			return;
		}

		self.backgroundRecordingID = UIBackgroundTaskInvalid;
		NSError *error = nil;

		AVCaptureDevice *videoDevice = [AAPLCameraViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:AVCaptureDevicePositionBack];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:&error];

		if ( ! videoDeviceInput ) {
			NSLog( @"Could not create video device input: %@", error );
		}

		[self.session beginConfiguration];

		if ( [self.session canAddInput:videoDeviceInput] ) {
			[self.session addInput:videoDeviceInput];
			self.videoDeviceInput = videoDeviceInput;

			dispatch_async( dispatch_get_main_queue(), ^{
				// Why are we dispatching this to the main queue?
				// Because AVCaptureVideoPreviewLayer is the backing layer for AAPLPreviewView and UIView
				// can only be manipulated on the main thread.
				// Note: As an exception to the above rule, it is not necessary to serialize video orientation changes
				// on the AVCaptureVideoPreviewLayer’s connection with other session manipulation.

				// Use the status bar orientation as the initial video orientation. Subsequent orientation changes are handled by
				// -[viewWillTransitionToSize:withTransitionCoordinator:].
				UIInterfaceOrientation statusBarOrientation = [UIApplication sharedApplication].statusBarOrientation;
				AVCaptureVideoOrientation initialVideoOrientation = AVCaptureVideoOrientationPortrait;
				if ( statusBarOrientation != UIInterfaceOrientationUnknown ) {
					initialVideoOrientation = (AVCaptureVideoOrientation)statusBarOrientation;
				}
				AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
                
				previewLayer.connection.videoOrientation = initialVideoOrientation;
			} );
		}
		else {
			NSLog( @"Could not add video device input to the session" );
			self.setupResult = AVCamSetupResultSessionConfigurationFailed;
		}

		AVCaptureDevice *audioDevice = [AVCaptureDevice defaultDeviceWithMediaType:AVMediaTypeAudio];
		AVCaptureDeviceInput *audioDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:audioDevice error:&error];

		if ( ! audioDeviceInput ) {
			NSLog( @"Could not create audio device input: %@", error );
		}

		if ( [self.session canAddInput:audioDeviceInput] ) {
			[self.session addInput:audioDeviceInput];
		}
		else {
			NSLog( @"Could not add audio device input to the session" );
		}

		AVCaptureMovieFileOutput *movieFileOutput = [[AVCaptureMovieFileOutput alloc] init];
		if ( [self.session canAddOutput:movieFileOutput] ) {
			[self.session addOutput:movieFileOutput];
			AVCaptureConnection *connection = [movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
			if ( connection.isVideoStabilizationSupported ) {
				connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
			}
			self.movieFileOutput = movieFileOutput;
		}
		else {
			NSLog( @"Could not add movie file output to the session" );
			self.setupResult = AVCamSetupResultSessionConfigurationFailed;
		}

		AVCaptureStillImageOutput *stillImageOutput = [[AVCaptureStillImageOutput alloc] init];
		if ( [self.session canAddOutput:stillImageOutput] ) {
			stillImageOutput.outputSettings = @{AVVideoCodecKey : AVVideoCodecJPEG};
			[self.session addOutput:stillImageOutput];
			self.stillImageOutput = stillImageOutput;
		}
		else {
			NSLog( @"Could not add still image output to the session" );
			self.setupResult = AVCamSetupResultSessionConfigurationFailed;
		}

        AVCaptureVideoDataOutput *videoDataOutput = [AVCaptureVideoDataOutput new];
        // we want BGRA, both CoreGraphics and OpenGL work well with 'BGRA'
        NSDictionary *rgbOutputSettings = [NSDictionary dictionaryWithObject:[NSNumber numberWithInt:kCMPixelFormat_32BGRA] forKey:(id)kCVPixelBufferPixelFormatTypeKey];
        [videoDataOutput setVideoSettings:rgbOutputSettings];
        
        [videoDataOutput setAlwaysDiscardsLateVideoFrames:YES];
        if ( [self.session canAddOutput:videoDataOutput] )
            [self.session addOutput:videoDataOutput];
        dispatch_queue_t videoDataQueue = dispatch_queue_create("VideoQueue", DISPATCH_QUEUE_SERIAL);
        [videoDataOutput setSampleBufferDelegate:self queue:videoDataQueue];


		[self.session commitConfiguration];
	} );
}

- (void)viewWillAppear:(BOOL)animated
{
	[super viewWillAppear:animated];
    
    [self.navigationController setNavigationBarHidden:YES];

    [self setPreviewImageViewVague];
    
    callTime = 0;
    tapCounter = 0;
    horizontalSwipeFactor = 0.0;
    zoomFactor = 1.0;
    previousZoomFactor = 1.0;
    
    [self startCountTime];
    dispatch_async( self.sessionQueue, ^{
		switch ( self.setupResult )
		{
			case AVCamSetupResultSuccess:
			{
				// Only setup observers and start the session running if setup succeeded.
				[self addObservers];
				[self.session startRunning];
				self.sessionRunning = self.session.isRunning;
//                [self toggleMovieRecording:nil];
				break;
			}
			case AVCamSetupResultCameraNotAuthorized:
			{
				dispatch_async( dispatch_get_main_queue(), ^{
					NSString *message = NSLocalizedString( @"AVCam doesn't have permission to use the camera, please change privacy settings", @"Alert message when the user has denied access to the camera" );
					UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
					UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
					[alertController addAction:cancelAction];
					// Provide quick access to Settings.
					UIAlertAction *settingsAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"Settings", @"Alert button to open Settings" ) style:UIAlertActionStyleDefault handler:^( UIAlertAction *action ) {
						[[UIApplication sharedApplication] openURL:[NSURL URLWithString:UIApplicationOpenSettingsURLString]];
					}];
					[alertController addAction:settingsAction];
					[self presentViewController:alertController animated:YES completion:nil];
				} );
				break;
			}
			case AVCamSetupResultSessionConfigurationFailed:
			{
				dispatch_async( dispatch_get_main_queue(), ^{
					NSString *message = NSLocalizedString( @"Unable to capture media", @"Alert message when something goes wrong during capture session configuration" );
					UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
					UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
					[alertController addAction:cancelAction];
					[self presentViewController:alertController animated:YES completion:nil];
				} );
				break;
			}
		}
	} );
    
    // set bg image accordint to device's screen
    CGRect screenRect = [[UIScreen mainScreen] bounds];
    [self.backgroundImageView setFrame:screenRect];

    NSLog(@"%@", NSStringFromCGRect(screenRect));
    CGRect previewRect = self.previewView.frame;
    NSLog(@"%@", NSStringFromCGRect(previewRect));
   
    if (UIDevice.currentDevice.userInterfaceIdiom == UIUserInterfaceIdiomPhone) {
        int height = (int) UIScreen.mainScreen.nativeBounds.size.height;
        int width = (int) UIScreen.mainScreen.nativeBounds.size.width;
        NSLog(@"height = %d, widht = %d", height, width);
        switch (height) {
            case 1136:
                NSLog(@"IPHONE 5,5S,5C");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone5"]];
                [self.previewView setFrame:CGRectMake(171, 201, 60, 60)];
                opticalZoomFactor = 1.0;
                break;
            case 1334:
                NSLog(@"IPHONE 6,7,8 IPHONE 6S,7S,8S ");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone6"]];
                [self.previewView setFrame:CGRectMake(202, 112, 60, 60)];
                opticalZoomFactor = 1.0;
                break;
            case 1920:
            case 2208:
                NSLog(@"IPHONE 6PLUS, 6SPLUS, 7PLUS, 8PLUS");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone6_plus"]];
                [self.previewView setFrame:CGRectMake(225, 138, 60, 60)];
                opticalZoomFactor = 2.0;
                break;
            case 2436:
                NSLog(@"IPHONE X, IPHONE XS");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphonexs"]];
                [self.previewView setFrame:CGRectMake(289, 378, 60, 60)];
                opticalZoomFactor = 2.0;
                break;
            case 2688:
                NSLog(@"IPHONE XS_MAX");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphonexs_max"]];
                [self.previewView setFrame:CGRectMake(32, 192, 60, 60)];
                opticalZoomFactor = 2.0;
                break;
            case 1792:
                NSLog(@"IPHONE XR");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphonexr"]];
                [self.previewView setFrame:CGRectMake(320, 193, 60, 60)];
                opticalZoomFactor = 1.0;
                break;
            case 2532:
                NSLog(@"IPHONE 12");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone12"]];
                [self.previewView setFrame:CGRectMake(120, 567, 60, 60)];
                opticalZoomFactor = 2.0;
                break;
            case 2778:
                NSLog(@"IPHONE 12 Pro Max");
                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone12_max"]];
                [self.previewView setFrame:CGRectMake(233, 296, 60, 60)];
                opticalZoomFactor = 2.5;
                break;
            default:
                NSLog(@"UNDETERMINED");
        }
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
	dispatch_async( self.sessionQueue, ^{
		if ( self.setupResult == AVCamSetupResultSuccess ) {
			[self.session stopRunning];
			[self removeObservers];
		}
	} );

	[super viewDidDisappear:animated];
    NSLog(@"hide the visual indicator for returning to the home screen");
    if (@available(iOS 11.0, *)) {
        [self setNeedsUpdateOfHomeIndicatorAutoHidden];
       }
}

-(BOOL)prefersStatusBarHidden {
    return YES;
}
-(BOOL)prefersHomeIndicatorAutoHidden {
    return YES;
}

#pragma mark Orientation

- (BOOL)shouldAutorotate
{
	// Disable autorotation of the interface when recording is in progress.
	return ! self.movieFileOutput.isRecording;
}

- (UIInterfaceOrientationMask)supportedInterfaceOrientations
{
	return UIInterfaceOrientationMaskAll;
}

- (void)viewWillTransitionToSize:(CGSize)size withTransitionCoordinator:(id<UIViewControllerTransitionCoordinator>)coordinator
{
	[super viewWillTransitionToSize:size withTransitionCoordinator:coordinator];

	// Note that the app delegate controls the device orientation notifications required to use the device orientation.
	UIDeviceOrientation deviceOrientation = [UIDevice currentDevice].orientation;
	if ( UIDeviceOrientationIsPortrait( deviceOrientation ) || UIDeviceOrientationIsLandscape( deviceOrientation ) ) {

        AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
		previewLayer.connection.videoOrientation = (AVCaptureVideoOrientation)deviceOrientation;
	}
}

#pragma mark KVO and Notifications

- (void)addObservers
{
	[self.session addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:SessionRunningContext];
	[self.stillImageOutput addObserver:self forKeyPath:@"capturingStillImage" options:NSKeyValueObservingOptionNew context:CapturingStillImageContext];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:self.videoDeviceInput.device];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
	// A session can only run when the app is full screen. It will be interrupted in a multi-app layout, introduced in iOS 9,
	// see also the documentation of AVCaptureSessionInterruptionReason. Add observers to handle these session interruptions
	// and show a preview is paused message. See the documentation of AVCaptureSessionWasInterruptedNotification for other
	// interruption reasons.
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.session];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.session];
}

- (void)removeObservers
{
	[[NSNotificationCenter defaultCenter] removeObserver:self];

	[self.session removeObserver:self forKeyPath:@"running" context:SessionRunningContext];
	[self.stillImageOutput removeObserver:self forKeyPath:@"capturingStillImage" context:CapturingStillImageContext];
}

- (void)observeValueForKeyPath:(NSString *)keyPath ofObject:(id)object change:(NSDictionary *)change context:(void *)context
{
	if ( context == CapturingStillImageContext ) {
		BOOL isCapturingStillImage = [change[NSKeyValueChangeNewKey] boolValue];

//		if ( isCapturingStillImage ) {
//			dispatch_async( dispatch_get_main_queue(), ^{
//				self.previewView.layer.opacity = 0.0;
//				[UIView animateWithDuration:0.25 animations:^{
//					self.previewView.layer.opacity = 0.6;
//				}];
//			} );
//		}
	}
	else if ( context == SessionRunningContext ) {
		BOOL isSessionRunning = [change[NSKeyValueChangeNewKey] boolValue];

		dispatch_async( dispatch_get_main_queue(), ^{
			// Only enable the ability to change camera if the device has more than one camera.
//			self.cameraButton.enabled = isSessionRunning && ( [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count > 1 );
//			self.recordButton.enabled = isSessionRunning;
//			self.stillButton.enabled = isSessionRunning;
		} );
	}
	else {
		[super observeValueForKeyPath:keyPath ofObject:object change:change context:context];
	}
}

- (void)subjectAreaDidChange:(NSNotification *)notification
{
	CGPoint devicePoint = CGPointMake( 0.5, 0.5 );
	[self focusWithMode:AVCaptureFocusModeContinuousAutoFocus exposeWithMode:AVCaptureExposureModeContinuousAutoExposure atDevicePoint:devicePoint monitorSubjectAreaChange:NO];
}

- (void)sessionRuntimeError:(NSNotification *)notification
{
	NSError *error = notification.userInfo[AVCaptureSessionErrorKey];
	NSLog( @"Capture session runtime error: %@", error );

	// Automatically try to restart the session running if media services were reset and the last start running succeeded.
	// Otherwise, enable the user to try to resume the session running.
	if ( error.code == AVErrorMediaServicesWereReset ) {
		dispatch_async( self.sessionQueue, ^{
			if ( self.isSessionRunning ) {
				[self.session startRunning];
				self.sessionRunning = self.session.isRunning;
			}
			else {
				dispatch_async( dispatch_get_main_queue(), ^{
//					self.resumeButton.hidden = NO;
				} );
			}
		} );
	}
	else {
//		self.resumeButton.hidden = NO;
	}
}

- (void)sessionWasInterrupted:(NSNotification *)notification
{
	// In some scenarios we want to enable the user to resume the session running.
	// For example, if music playback is initiated via control center while using AVCam,
	// then the user can let AVCam resume the session running, which will stop music playback.
	// Note that stopping music playback in control center will not automatically resume the session running.
	// Also note that it is not always possible to resume, see -[resumeInterruptedSession:].
	BOOL showResumeButton = NO;

	// In iOS 9 and later, the userInfo dictionary contains information on why the session was interrupted.
	if ( &AVCaptureSessionInterruptionReasonKey ) {
		AVCaptureSessionInterruptionReason reason = [notification.userInfo[AVCaptureSessionInterruptionReasonKey] integerValue];
		NSLog( @"Capture session was interrupted with reason %ld", (long)reason );

		if ( reason == AVCaptureSessionInterruptionReasonAudioDeviceInUseByAnotherClient ||
			 reason == AVCaptureSessionInterruptionReasonVideoDeviceInUseByAnotherClient ) {
			showResumeButton = YES;
		}
		else if ( reason == AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps ) {
			// Simply fade-in a label to inform the user that the camera is unavailable.
//			self.cameraUnavailableLabel.hidden = NO;
//			self.cameraUnavailableLabel.alpha = 0.0;
//			[UIView animateWithDuration:0.25 animations:^{
//				self.cameraUnavailableLabel.alpha = 1.0;
//			}];
		}
	}
	else {
		NSLog( @"Capture session was interrupted" );
		showResumeButton = ( [UIApplication sharedApplication].applicationState == UIApplicationStateInactive );
	}

	if ( showResumeButton ) {
		// Simply fade-in a button to enable the user to try to resume the session running.
//		self.resumeButton.hidden = NO;
//		self.resumeButton.alpha = 0.0;
//		[UIView animateWithDuration:0.25 animations:^{
//			self.resumeButton.alpha = 1.0;
//		}];
	}
}

- (void)sessionInterruptionEnded:(NSNotification *)notification
{
	NSLog( @"Capture session interruption ended" );

//	if ( ! self.resumeButton.hidden ) {
//		[UIView animateWithDuration:0.25 animations:^{
//			self.resumeButton.alpha = 0.0;
//		} completion:^( BOOL finished ) {
//			self.resumeButton.hidden = YES;
//		}];
//	}
//	if ( ! self.cameraUnavailableLabel.hidden ) {
//		[UIView animateWithDuration:0.25 animations:^{
//			self.cameraUnavailableLabel.alpha = 0.0;
//		} completion:^( BOOL finished ) {
//			self.cameraUnavailableLabel.hidden = YES;
//		}];
//	}
}

- (void)applicationEnteredForeground:(NSNotification *)notification {
    NSLog(@"Application Entered Foreground");
//    [self toggleMovieRecording:nil];
}

#pragma mark Actions

- (IBAction)resumeInterruptedSession:(id)sender
{
	dispatch_async( self.sessionQueue, ^{
		// The session might fail to start running, e.g., if a phone or FaceTime call is still using audio or video.
		// A failure to start the session running will be communicated via a session runtime error notification.
		// To avoid repeatedly failing to start the session running, we only try to restart the session running in the
		// session runtime error handler if we aren't trying to resume the session running.
		[self.session startRunning];
		self.sessionRunning = self.session.isRunning;
		if ( ! self.session.isRunning ) {
			dispatch_async( dispatch_get_main_queue(), ^{
				NSString *message = NSLocalizedString( @"Unable to resume", @"Alert message when unable to resume the session running" );
				UIAlertController *alertController = [UIAlertController alertControllerWithTitle:@"AVCam" message:message preferredStyle:UIAlertControllerStyleAlert];
				UIAlertAction *cancelAction = [UIAlertAction actionWithTitle:NSLocalizedString( @"OK", @"Alert OK button" ) style:UIAlertActionStyleCancel handler:nil];
				[alertController addAction:cancelAction];
				[self presentViewController:alertController animated:YES completion:nil];
			} );
		}
		else {
			dispatch_async( dispatch_get_main_queue(), ^{
//				self.resumeButton.hidden = YES;
			} );
		}
	} );
}

- (NSString *)documentsPathForFileName:(NSString *)name
{
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory,NSUserDomainMask, YES);
    NSString *documentsPath = [paths objectAtIndex:0];
    
    return [documentsPath stringByAppendingPathComponent:name];
}


- (IBAction)toggleMovieRecording:(id)sender
{
	// Disable the Camera button until recording finishes, and disable the Record button until recording starts or finishes. See the
	// AVCaptureFileOutputRecordingDelegate methods.
//	self.cameraButton.enabled = NO;
//	self.recordButton.enabled = NO;

	dispatch_async( self.sessionQueue, ^{
		if ( ! self.movieFileOutput.isRecording ) {
			if ( [UIDevice currentDevice].isMultitaskingSupported ) {
				// Setup background task. This is needed because the -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:]
				// callback is not received until AVCam returns to the foreground unless you request background execution time.
				// This also ensures that there will be time to write the file to the photo library when AVCam is backgrounded.
				// To conclude this background execution, -endBackgroundTask is called in
				// -[captureOutput:didFinishRecordingToOutputFileAtURL:fromConnections:error:] after the recorded file has been saved.
				self.backgroundRecordingID = [[UIApplication sharedApplication] beginBackgroundTaskWithExpirationHandler:nil];
			}

			// Update the orientation on the movie file output video connection before starting recording.
			AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
            
            // To stop the warning of UI updating in background
            dispatch_async(dispatch_get_main_queue(), ^{
        
                AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
                connection.videoOrientation = previewLayer.connection.videoOrientation;
            });

			// Turn OFF flash for video recording.
			[AAPLCameraViewController setFlashMode:AVCaptureFlashModeOff forDevice:self.videoDeviceInput.device];
            [AAPLCameraViewController setZoomFactor: 1.0 forDevice:self.videoDeviceInput.device];
            
			// Start recording to a temporary file.
//			NSString *outputFileName = [NSProcessInfo processInfo].globallyUniqueString;
//			NSString *outputFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[outputFileName stringByAppendingPathExtension:@"mov"]];
            
            NSString * timestampString = [NSString stringWithFormat:@"%.0f",[[NSDate date] timeIntervalSince1970]*1000000];
            NSString *outputFilePath = [self documentsPathForFileName:[NSString stringWithFormat:@"%@.mov",timestampString]]; //Add the file name
			[self.movieFileOutput startRecordingToOutputFileURL:[NSURL fileURLWithPath:outputFilePath] recordingDelegate:self];
		}
		else {
			[self.movieFileOutput stopRecording];
		}
	} );
}

- (IBAction)changeCamera:(id)sender
{
//	self.cameraButton.enabled = NO;
//	self.recordButton.enabled = NO;
//	self.stillButton.enabled = NO;

	dispatch_async( self.sessionQueue, ^{
		AVCaptureDevice *currentVideoDevice = self.videoDeviceInput.device;
		AVCaptureDevicePosition preferredPosition = AVCaptureDevicePositionUnspecified;
		AVCaptureDevicePosition currentPosition = currentVideoDevice.position;

		switch ( currentPosition )
		{
			case AVCaptureDevicePositionUnspecified:
			case AVCaptureDevicePositionFront:
				preferredPosition = AVCaptureDevicePositionBack;
				break;
			case AVCaptureDevicePositionBack:
				preferredPosition = AVCaptureDevicePositionFront;
				break;
		}

		AVCaptureDevice *videoDevice = [AAPLCameraViewController deviceWithMediaType:AVMediaTypeVideo preferringPosition:preferredPosition];
		AVCaptureDeviceInput *videoDeviceInput = [AVCaptureDeviceInput deviceInputWithDevice:videoDevice error:nil];

		[self.session beginConfiguration];

		// Remove the existing device input first, since using the front and back camera simultaneously is not supported.
		[self.session removeInput:self.videoDeviceInput];

		if ( [self.session canAddInput:videoDeviceInput] ) {
			[[NSNotificationCenter defaultCenter] removeObserver:self name:AVCaptureDeviceSubjectAreaDidChangeNotification object:currentVideoDevice];

			[AAPLCameraViewController setFlashMode:AVCaptureFlashModeAuto forDevice:videoDevice];
			[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:videoDevice];

			[self.session addInput:videoDeviceInput];
			self.videoDeviceInput = videoDeviceInput;
		}
		else {
			[self.session addInput:self.videoDeviceInput];
		}

		AVCaptureConnection *connection = [self.movieFileOutput connectionWithMediaType:AVMediaTypeVideo];
		if ( connection.isVideoStabilizationSupported ) {
			connection.preferredVideoStabilizationMode = AVCaptureVideoStabilizationModeAuto;
		}

		[self.session commitConfiguration];

		dispatch_async( dispatch_get_main_queue(), ^{
//			self.cameraButton.enabled = YES;
//			self.recordButton.enabled = YES;
//			self.stillButton.enabled = YES;
		} );
	} );
}

- (IBAction)snapStillImage:(id)sender
{
//	dispatch_async( self.sessionQueue, ^{
//		AVCaptureConnection *connection = [self.stillImageOutput connectionWithMediaType:AVMediaTypeVideo];
//		AVCaptureVideoPreviewLayer *previewLayer = (AVCaptureVideoPreviewLayer *)self.previewView.layer;
//
//		// Update the orientation on the still image output video connection before capturing.
//		connection.videoOrientation = previewLayer.connection.videoOrientation;
//
//		// Flash set to Auto for Still Capture.
//		[AAPLCameraViewController setFlashMode:AVCaptureFlashModeAuto forDevice:self.videoDeviceInput.device];
//
//		// Capture a still image.
//		[self.stillImageOutput captureStillImageAsynchronouslyFromConnection:connection completionHandler:^( CMSampleBufferRef imageDataSampleBuffer, NSError *error ) {
//			if ( imageDataSampleBuffer ) {
//				// The sample buffer is not retained. Create image data before saving the still image to the photo library asynchronously.
//				NSData *imageData = [AVCaptureStillImageOutput jpegStillImageNSDataRepresentation:imageDataSampleBuffer];
//				[PHPhotoLibrary requestAuthorization:^( PHAuthorizationStatus status ) {
//					if ( status == PHAuthorizationStatusAuthorized ) {
//						// To preserve the metadata, we create an asset from the JPEG NSData representation.
//						// Note that creating an asset from a UIImage discards the metadata.
//						// In iOS 9, we can use -[PHAssetCreationRequest addResourceWithType:data:options].
//						// In iOS 8, we save the image to a temporary file and use +[PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:].
//						if ( [PHAssetCreationRequest class] ) {
//							[[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
//								[[PHAssetCreationRequest creationRequestForAsset] addResourceWithType:PHAssetResourceTypePhoto data:imageData options:nil];
//							} completionHandler:^( BOOL success, NSError *error ) {
//								if ( ! success ) {
//									NSLog( @"Error occurred while saving image to photo library: %@", error );
//								}
//							}];
//						}
//						else {
//							NSString *temporaryFileName = [NSProcessInfo processInfo].globallyUniqueString;
//							NSString *temporaryFilePath = [NSTemporaryDirectory() stringByAppendingPathComponent:[temporaryFileName stringByAppendingPathExtension:@"jpg"]];
//							NSURL *temporaryFileURL = [NSURL fileURLWithPath:temporaryFilePath];
//
//							[[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
//								NSError *error = nil;
//								[imageData writeToURL:temporaryFileURL options:NSDataWritingAtomic error:&error];
//								if ( error ) {
//									NSLog( @"Error occured while writing image data to a temporary file: %@", error );
//								}
//								else {
//									[PHAssetChangeRequest creationRequestForAssetFromImageAtFileURL:temporaryFileURL];
//								}
//							} completionHandler:^( BOOL success, NSError *error ) {
//								if ( ! success ) {
//									NSLog( @"Error occurred while saving image to photo library: %@", error );
//								}
//
//								// Delete the temporary file.
//								[[NSFileManager defaultManager] removeItemAtURL:temporaryFileURL error:nil];
//							}];
//						}
//					}
//				}];
//			}
//			else {
//				NSLog( @"Could not capture still image: %@", error );
//			}
//		}];
//	} );
}

- (IBAction)focusAndExposeTap:(UIGestureRecognizer *)gestureRecognizer
{
    CGPoint devicePoint = [(AVCaptureVideoPreviewLayer *)self.previewView.layer captureDevicePointOfInterestForPoint:[gestureRecognizer locationInView:gestureRecognizer.view]];
	[self focusWithMode:AVCaptureFocusModeAutoFocus exposeWithMode:AVCaptureExposureModeAutoExpose atDevicePoint:devicePoint monitorSubjectAreaChange:YES];
}
- (IBAction)exitButtonPressed:(id)sender {
    exit(1);
}

#pragma mark - Video Data Output Delegate

- (void)captureOutput:(AVCaptureOutput *)captureOutput didOutputSampleBuffer:(CMSampleBufferRef)sampleBuffer fromConnection:(AVCaptureConnection *)connection {
    
    NSLog(@"capture output delegate");
    /*
     // Get a CMSampleBuffer's Core Video image buffer for the media data
     CVImageBufferRef imageBuffer = CMSampleBufferGetImageBuffer(sampleBuffer);
     // Lock the base address of the pixel buffer
     CVPixelBufferLockBaseAddress(imageBuffer, 0);
     
     // Get the number of bytes per row for the pixel buffer
     void *baseAddress = CVPixelBufferGetBaseAddress(imageBuffer);
     
     // Get the number of bytes per row for the pixel buffer
     size_t bytesPerRow = CVPixelBufferGetBytesPerRow(imageBuffer);
     // Get the pixel buffer width and height
     size_t width = CVPixelBufferGetWidth(imageBuffer);
     size_t height = CVPixelBufferGetHeight(imageBuffer);
     
     // Create a device-dependent RGB color space
     CGColorSpaceRef colorSpace = CGColorSpaceCreateDeviceRGB();
     
     // Create a bitmap graphics context with the sample buffer data
     CGContextRef context = CGBitmapContextCreate(baseAddress, width, height, 8,
     bytesPerRow, colorSpace, kCGBitmapByteOrder32Little | kCGImageAlphaPremultipliedFirst);
     // Create a Quartz image from the pixel data in the bitmap graphics context
     CGImageRef quartzImage = CGBitmapContextCreateImage(context);
     // Unlock the pixel buffer
     CVPixelBufferUnlockBaseAddress(imageBuffer,0);
     
     
     // Free up the context and color space
     CGContextRelease(context);
     //    CGColorSpaceRelease(colorSpace);
     
     // binary image processing
     UIImage *image = [UIImage imageWithCGImage:quartzImage];
     UIImageToMat(image, cvImage);
     
     if (_isShowingRawPreviewImage == NO) {
     
     cv::Mat grayImage;
     cv::cvtColor(cvImage, grayImage, CV_RGBA2GRAY);
     cv::dilate(grayImage, grayImage, cv::Mat(), cv::Point(-1,-1));
     cv::threshold(grayImage, grayImage, 55, 255, CV_THRESH_BINARY | CV_THRESH_OTSU);
     cv::GaussianBlur(grayImage, grayImage, cv::Size(5, 5), 1.2);
     cvImage = grayImage;
     
     
     //    // line portrait image processing
     //    UIImage *image = [UIImage imageWithCGImage:quartzImage];
     //    UIImageToMat(image, cvImage);
     //    cv::Mat grayImage;
     //    cv::cvtColor(cvImage, grayImage, CV_RGBA2GRAY);
     //    cv::GaussianBlur(grayImage, grayImage, cv::Size(5, 5), 1.2);
     //    cv::Mat edges;
     //    cv::Canny(grayImage, edges, 0, 50);
     //    cvImage.setTo(cv::Scalar(255,255,255));
     //    cvImage.setTo(cv::Scalar(0, 0, 0, 0), edges); // color code
     //    edges.release();
     
     grayImage.release();
     
     }
     
     dispatch_sync(dispatch_get_main_queue(), ^{
     _customPreviewLayer.contents = (__bridge id)(MatToUIImage(cvImage)).CGImage;;
     });
     CGImageRelease(quartzImage);
     */
}


#pragma mark File Output Recording Delegate

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections
{
	// Enable the Record button to let the user stop the recording.
	dispatch_async( dispatch_get_main_queue(), ^{
        [self setPreviewImageViewClear];
        callTime = 0;
//        self.statusBarIndicator.backgroundColor = [UIColor colorWithRed:0.5 green:0.1 blue:0 alpha:0.5];
//		self.recordButton.enabled = YES;
//		[self.recordButton setTitle:NSLocalizedString( @"Stop", @"Recording button stop title") forState:UIControlStateNormal];
	});
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
	// Note that currentBackgroundRecordingID is used to end the background task associated with this recording.
	// This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's isRecording property
	// is back to NO — which happens sometime after this method returns.
	// Note: Since we use a unique file path for each recording, a new recording will not overwrite a recording currently being saved.
//	UIBackgroundTaskIdentifier currentBackgroundRecordingID = self.backgroundRecordingID;
	self.backgroundRecordingID = UIBackgroundTaskInvalid;

	dispatch_block_t cleanup = ^{
//		[[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
//		if ( currentBackgroundRecordingID != UIBackgroundTaskInvalid ) {
//			[[UIApplication sharedApplication] endBackgroundTask:currentBackgroundRecordingID];
//		}
	};

	BOOL success = YES;

	if ( error ) {
		NSLog( @"Movie file finishing error: %@", error );
		success = [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
	}
	if ( success ) {
		// Check authorization status.
//		[PHPhotoLibrary requestAuthorization:^( PHAuthorizationStatus status ) {
//			if ( status == PHAuthorizationStatusAuthorized ) {
//				// Save the movie file to the photo library and cleanup.
//				[[PHPhotoLibrary sharedPhotoLibrary] performChanges:^{
//					// In iOS 9 and later, it's possible to move the file into the photo library without duplicating the file data.
//					// This avoids using double the disk space during save, which can make a difference on devices with limited free disk space.
//					if ( [PHAssetResourceCreationOptions class] ) {
//						PHAssetResourceCreationOptions *options = [[PHAssetResourceCreationOptions alloc] init];
//						options.shouldMoveFile = YES;
//						PHAssetCreationRequest *changeRequest = [PHAssetCreationRequest creationRequestForAsset];
//						[changeRequest addResourceWithType:PHAssetResourceTypeVideo fileURL:outputFileURL options:options];
//					}
//					else {
//						[PHAssetChangeRequest creationRequestForAssetFromVideoAtFileURL:outputFileURL];
//					}
//				} completionHandler:^( BOOL success, NSError *error ) {
//					if ( ! success ) {
//						NSLog( @"Could not save movie to photo library: %@", error );
//					}
//					cleanup();
//				}];
//			}
//			else {
//				cleanup();
//			}
//		}];
	}
	else {
		cleanup();
	}

	// Enable the Camera and Record buttons to let the user switch camera and start another recording.
	dispatch_async( dispatch_get_main_queue(), ^{
        [self setPreviewImageViewVague];
//        self.statusBarIndicator.backgroundColor = [UIColor colorWithRed:0 green:0 blue:0 alpha:0];

		// Only enable the ability to change camera if the device has more than one camera.
//		self.cameraButton.enabled = ( [AVCaptureDevice devicesWithMediaType:AVMediaTypeVideo].count > 1 );
//		self.recordButton.enabled = YES;
//		[self.recordButton setTitle:NSLocalizedString( @"Record", @"Recording button record title" ) forState:UIControlStateNormal];
	});
}

#pragma mark - touch functions

- (void) touchesBegan:(NSSet *)touches
            withEvent:(UIEvent *)event {
    
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self.view];
    lastTouchedPointX = point.x;
    lastTouchedPointY = point.y;
    
}

- (void) touchesMoved:(NSSet *)touches
            withEvent:(UIEvent *)event {
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self.view];
    CGFloat pointX = point.x;
    CGFloat pointY = point.y;
    CGFloat xDist = (pointX - lastTouchedPointX);
    CGFloat yDist = (pointY - lastTouchedPointY);
    CGFloat distance = sqrt((xDist * xDist) + (yDist * yDist));
    CGFloat xDisplacement = pointX - lastTouchedPointX;
    
    // handle horizontal swipe for zoom
    horizontalSwipeFactor = xDisplacement / 100.0;
    zoomFactor = previousZoomFactor + horizontalSwipeFactor;
    zoomFactor = zoomFactor > opticalZoomFactor ?opticalZoomFactor : zoomFactor;
    zoomFactor = zoomFactor < 1.0 ? 1.0 : zoomFactor;
    
    if (self.movieFileOutput.isRecording == YES) {
        NSLog(@"horizontalSwipefactor= %f", horizontalSwipeFactor);
        NSLog(@"zoomFactor= %f", zoomFactor);
        [AAPLCameraViewController setZoomFactor: zoomFactor forDevice:self.videoDeviceInput.device];
    }

    // clean tapCounter if swiping
    if (distance >= 20.0) {
        tapCounter = 0;
    }
}

- (void) touchesEnded:(NSSet *)touches
            withEvent:(UIEvent *)event {
    
    
    UITouch *touch = [touches anyObject];
    CGPoint point = [touch locationInView:self.view];
    CGFloat pointX = point.x;
    CGFloat pointY = point.y;
    CGFloat xDist = (pointX - lastTouchedPointX);
    CGFloat yDist = (pointY - lastTouchedPointY);
    CGFloat distance = sqrt((xDist * xDist) + (yDist * yDist));
    CGFloat yDisplacement = pointY - lastTouchedPointY;
    
    //    NSLog(@"moved distance %.0f",distance);
    
    // store current zoom factor
    previousZoomFactor =  zoomFactor;
    
    //handle tap gesture
    
    // start timer for the first tap
    if (tapCounter == 0) {
        startTime = CACurrentMediaTime();
    }
    
    elapsedTime = CACurrentMediaTime() - startTime;
    
    // defining what a single and a double tap are
    if (elapsedTime > 0.8) {
        tapCounter = 0;
    } else if (distance < 20.0 && elapsedTime < 0.3) {
        tapCounter++;
    } else {
        tapCounter = 0;
    }

    if (tapCounter >= 2) {
        tapCounter = 0;
        [self showCollectionView];
    }
    NSLog(@"tapCounter = %d", tapCounter);
    
    // handle swipe down gesture. Start recording
    if (yDist >= 80.0  && elapsedTime > 0.0 && (self.movieFileOutput.isRecording == NO)) {
        
        tapCounter = 0; // not a tap. it is a swipe. safeguard. it should be 0 anyway! for it will be cleaned when distance
        
        [self setPreviewImageViewClear];
        [self toggleMovieRecording:nil];
        return;
    }
    
    // turn off recording
    if (self.movieFileOutput.isRecording == YES && tapCounter > 0) {
        tapCounter = 0;
        [self toggleMovieRecording:nil];
        zoomFactor = 1.0;
        
        return;
    }

}

- (void)setPreviewImageViewClear {
    self.previewView.alpha = 0.6;
//    [self.crossHairLabel setHidden:NO];
    
}

- (void)setPreviewImageViewVague {
    self.previewView.alpha = 0.0;
//    [self.crossHairLabel setHidden:YES];
    
}

#pragma mark Device Configuration

- (void)focusWithMode:(AVCaptureFocusMode)focusMode exposeWithMode:(AVCaptureExposureMode)exposureMode atDevicePoint:(CGPoint)point monitorSubjectAreaChange:(BOOL)monitorSubjectAreaChange
{
	dispatch_async( self.sessionQueue, ^{
		AVCaptureDevice *device = self.videoDeviceInput.device;
		NSError *error = nil;
		if ( [device lockForConfiguration:&error] ) {
			// Setting (focus/exposure)PointOfInterest alone does not initiate a (focus/exposure) operation.
			// Call -set(Focus/Exposure)Mode: to apply the new point of interest.
			if ( device.isFocusPointOfInterestSupported && [device isFocusModeSupported:focusMode] ) {
				device.focusPointOfInterest = point;
				device.focusMode = focusMode;
			}

			if ( device.isExposurePointOfInterestSupported && [device isExposureModeSupported:exposureMode] ) {
				device.exposurePointOfInterest = point;
				device.exposureMode = exposureMode;
			}

			device.subjectAreaChangeMonitoringEnabled = monitorSubjectAreaChange;
			[device unlockForConfiguration];
		}
		else {
			NSLog( @"Could not lock device for configuration: %@", error );
		}
	} );
}

+ (void)setFlashMode:(AVCaptureFlashMode)flashMode forDevice:(AVCaptureDevice *)device
{
	if ( device.hasFlash && [device isFlashModeSupported:flashMode] ) {
		NSError *error = nil;
		if ( [device lockForConfiguration:&error] ) {
			device.flashMode = flashMode;
			[device unlockForConfiguration];
		}
		else {
			NSLog( @"Could not lock device for configuration: %@", error );
		}
	}
}

+ (void)setZoomFactor:(double)zoomFactor forDevice:(AVCaptureDevice *)device
{
//    NSLog(@"minAvailableVideoZoomFactor = %f",  device.minAvailableVideoZoomFactor);
    if (zoomFactor<= device.maxAvailableVideoZoomFactor && zoomFactor>= device.minAvailableVideoZoomFactor) {
        NSError *error = nil;
        if ( [device lockForConfiguration:&error] ) {
            device.videoZoomFactor = zoomFactor;
            [device unlockForConfiguration];
        }
        else {
            NSLog( @"Could not lock device for configuration: %@", error );
        }
    }
}

+ (AVCaptureDevice *)deviceWithMediaType:(NSString *)mediaType preferringPosition:(AVCaptureDevicePosition)position
{
	NSArray *devices = [AVCaptureDevice devicesWithMediaType:mediaType];
	AVCaptureDevice *captureDevice = devices.firstObject;

	for ( AVCaptureDevice *device in devices ) {
		if ( device.position == position ) {
			captureDevice = device;
			break;
		}
	}

	return captureDevice;
}
#pragma mark - timer animation

- (void) startCountTime {
    NSTimer* timer = [NSTimer timerWithTimeInterval:1.0f target:self selector:@selector(updateLabel:) userInfo:nil repeats:YES];
    [[NSRunLoop mainRunLoop] addTimer:timer forMode:NSRunLoopCommonModes];
}

-(void)updateLabel:(id)sender {
    dispatch_async(dispatch_get_main_queue(), ^{
        callTime++;
//        self.callTimerLabel.text = [NSString stringWithFormat:@"%d:%02d", callTime /60, callTime % 60];
    });
}
#pragma mark - callback

- (void)showCollectionView {
    NSLog(@"showCollectionView");
    [self performSegueWithIdentifier:@"ToCollectionView" sender:self];
}

@end
