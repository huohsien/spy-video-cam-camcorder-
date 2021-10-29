@import AVFoundation;
@import Photos;

#import <sys/utsname.h>
#import "AAPLCameraViewController.h"

static void * CapturingStillImageContext = &CapturingStillImageContext;
static void * SessionRunningContext = &SessionRunningContext;

typedef NS_ENUM( NSInteger, AVCamSetupResult ) {
	AVCamSetupResultSuccess,
	AVCamSetupResultCameraNotAuthorized,
	AVCamSetupResultSessionConfigurationFailed
};

//@interface UINavigationController(custom)
//@end
//@implementation UINavigationController(custom)
//-(UIViewController *)childViewControllerForHomeIndicatorAutoHidden{
//    return [self.storyboard  instantiateViewControllerWithIdentifier:@"AAPLCameraViewController"];
//}
//@end

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
        
        struct utsname systemInfo;
        uname(&systemInfo);

        NSString* deviceModel = [NSString stringWithCString:systemInfo.machine
                                  encoding:NSUTF8StringEncoding];
        NSLog(@"deviceModel= %@", deviceModel);
        
        if ([deviceModel isEqual: @"iPhone14,3"]) {
            NSLog(@"IPHONE 13 Pro Max");
            [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone13_max"]];
            [self.previewView setFrame:CGRectMake(27, 68, 60, 60)];
            opticalZoomFactor = 3.0;
        } else if ([deviceModel isEqual: @"iPhone14,4"]) {
            NSLog(@"IPHONE 13 mini");
            [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone12_mini"]];
            [self.previewView setFrame:CGRectMake(202, 77, 60, 60)];
            opticalZoomFactor = 2.0;
        } else if ([deviceModel isEqual: @"iPhone14,2"]) {
            NSLog(@"IPHONE 13 Pro");
            [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone13"]];
            [self.previewView setFrame:CGRectMake(300, 567, 60, 60)];
            opticalZoomFactor = 3.0;
        }

        int height = (int) UIScreen.mainScreen.nativeBounds.size.height;
        int width = (int) UIScreen.mainScreen.nativeBounds.size.width;
        NSLog(@"height = %d, widht = %d", height, width);
//        switch (height) {
//            case 1136:
//                NSLog(@"IPHONE 5,5S,5C");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone5"]];
//                [self.previewView setFrame:CGRectMake(171, 201, 60, 60)];
//                opticalZoomFactor = 1.0;
//                break;
//            case 1334:
//                NSLog(@"IPHONE 6,7,8 IPHONE 6S,7S,8S ");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone6"]];
//                [self.previewView setFrame:CGRectMake(202, 112, 60, 60)];
//                opticalZoomFactor = 1.0;
//                break;
//            case 1920:
//            case 2208:
//                NSLog(@"IPHONE 6PLUS, 6SPLUS, 7PLUS, 8PLUS");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone6_plus"]];
//                [self.previewView setFrame:CGRectMake(225, 138, 60, 60)];
//                opticalZoomFactor = 2.0;
//                break;
//            case 2436:
//                NSLog(@"IPHONE X, IPHONE XS");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphonexs"]];
//                [self.previewView setFrame:CGRectMake(289, 378, 60, 60)];
//                opticalZoomFactor = 2.0;
//                break;
//            case 2688:
//                NSLog(@"IPHONE XS_MAX");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphonexs_max"]];
//                [self.previewView setFrame:CGRectMake(32, 192, 60, 60)];
//                opticalZoomFactor = 2.0;
//                break;
//            case 1792:
//                NSLog(@"IPHONE XR");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphonexr"]];
//                [self.previewView setFrame:CGRectMake(320, 193, 60, 60)];
//                opticalZoomFactor = 1.0;
//                break;
//            case 2532:
//                NSLog(@"IPHONE 12");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone12"]];
//                [self.previewView setFrame:CGRectMake(120, 567, 60, 60)];
//                opticalZoomFactor = 2.0;
//                break;
//            case 2778:
//                NSLog(@"IPHONE 12 Pro Max");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone12_max"]];
//                [self.previewView setFrame:CGRectMake(233, 296, 60, 60)];
//                opticalZoomFactor = 2.5;
//                break;
//            case 2340:
//                NSLog(@"IPHONE 12 mini");
//                [self.backgroundImageView setImage:[UIImage imageNamed:@"bg_iphone12_mini"]];
//                [self.previewView setFrame:CGRectMake(202, 77, 60, 60)];
//                opticalZoomFactor = 2;
//                break;
//            default:
//                NSLog(@"UNDETERMINED");
//        }
    }
}

- (void)viewDidDisappear:(BOOL)animated
{
	dispatch_async( self.sessionQueue, ^{
		if ( self.setupResult == AVCamSetupResultSuccess ) {
			[self.session stopRunning];
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
//	[self.session addObserver:self forKeyPath:@"running" options:NSKeyValueObservingOptionNew context:SessionRunningContext];
//	[self.stillImageOutput addObserver:self forKeyPath:@"capturingStillImage" options:NSKeyValueObservingOptionNew context:CapturingStillImageContext];

	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(subjectAreaDidChange:) name:AVCaptureDeviceSubjectAreaDidChangeNotification object:self.videoDeviceInput.device];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionRuntimeError:) name:AVCaptureSessionRuntimeErrorNotification object:self.session];
	// A session can only run when the app is full screen. It will be interrupted in a multi-app layout, introduced in iOS 9,
	// see also the documentation of AVCaptureSessionInterruptionReason. Add observers to handle these session interruptions
	// and show a preview is paused message. See the documentation of AVCaptureSessionWasInterruptedNotification for other
	// interruption reasons.
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionWasInterrupted:) name:AVCaptureSessionWasInterruptedNotification object:self.session];
	[[NSNotificationCenter defaultCenter] addObserver:self selector:@selector(sessionInterruptionEnded:) name:AVCaptureSessionInterruptionEndedNotification object:self.session];
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
            NSLog(@"AVCaptureSessionInterruptionReasonVideoDeviceNotAvailableWithMultipleForegroundApps");
		}
	}
	else {
		NSLog( @"Capture session was interrupted" );
		showResumeButton = ( [UIApplication sharedApplication].applicationState == UIApplicationStateInactive );
	}

	if (showResumeButton) {
        NSLog(@"showResumeButton");
	}
}

- (void)sessionInterruptionEnded:(NSNotification *)notification
{
	NSLog( @"Capture session interruption ended" );
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

#pragma mark File Output Recording Delegate

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didStartRecordingToOutputFileAtURL:(NSURL *)fileURL fromConnections:(NSArray *)connections
{
	// Turn on Preview
	dispatch_async( dispatch_get_main_queue(), ^{
        [self setPreviewImageViewClear];
	});
}

- (void)captureOutput:(AVCaptureFileOutput *)captureOutput didFinishRecordingToOutputFileAtURL:(NSURL *)outputFileURL fromConnections:(NSArray *)connections error:(NSError *)error
{
	// Note that currentBackgroundRecordingID is used to end the background task associated with this recording.
	// This allows a new recording to be started, associated with a new UIBackgroundTaskIdentifier, once the movie file output's isRecording property
	// is back to NO — which happens sometime after this method returns.
	// Note: Since we use a unique file path for each recording, a new recording will not overwrite a recording currently being saved.
	UIBackgroundTaskIdentifier currentBackgroundRecordingID = self.backgroundRecordingID;
	self.backgroundRecordingID = UIBackgroundTaskInvalid;

	dispatch_block_t cleanup = ^{
		[[NSFileManager defaultManager] removeItemAtURL:outputFileURL error:nil];
		if ( currentBackgroundRecordingID != UIBackgroundTaskInvalid ) {
			[[UIApplication sharedApplication] endBackgroundTask:currentBackgroundRecordingID];
		}
	};

	BOOL success = YES;

	if ( error ) {
		NSLog( @"Movie file finishing error: %@", error );
		success = [error.userInfo[AVErrorRecordingSuccessfullyFinishedKey] boolValue];
	}
	if (!success) {
		cleanup();
	}

	// Enable the Camera and Record buttons to let the user switch camera and start another recording.
	dispatch_async( dispatch_get_main_queue(), ^{
        [self setPreviewImageViewVague];
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
}

- (void)setPreviewImageViewVague {
    self.previewView.alpha = 0.0;
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
    if (@available(iOS 11.0, *)) {
        //    NSLog(@"minAvailableVideoZoomFactor = %f",  device.minAvailableVideoZoomFactor);
            if (zoomFactor > device.maxAvailableVideoZoomFactor || zoomFactor < device.minAvailableVideoZoomFactor) {
                NSLog(@"failed to change zoom factor.so set it to default value 1.0");
                zoomFactor = 1.0;
            }
        NSError *error = nil;
        if ( [device lockForConfiguration:&error] ) {
            device.videoZoomFactor = zoomFactor;
            [device unlockForConfiguration];
        }
        else {
            NSLog( @"Could not lock device for configuration: %@", error );
        }
    } else {
        NSLog(@"iOS version is lower than 11.0. Does not implement zoom function for these cases");
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

#pragma mark - callback

- (void)showCollectionView {
    NSLog(@"showCollectionView");
    [self performSegueWithIdentifier:@"ToCollectionView" sender:self];
}

@end
