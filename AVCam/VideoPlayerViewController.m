//
//  VideoPlayerViewController.m
//  AVCam
//
//  Created by victor on 12/24/15.
//
//

#import "VideoPlayerViewController.h"
#import "AVFoundation/AVFoundation.h"
#import "AVKit/AVkit.h"
@implementation VideoPlayerViewController
@synthesize filePath = _filePath;

- (void)viewDidLoad {
    
    [super viewDidLoad];
    
    [self.navigationController setNavigationBarHidden:YES];

    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *videoPath = [NSString stringWithFormat:@"%@/%@", documentsDirectory, self.filePath];
    NSURL *fileURL = [NSURL fileURLWithPath:videoPath];
    self.player = [AVPlayer playerWithURL:fileURL];
    [self.player play];
//    self.showsPlaybackControls = NO;
    
}

//- (void)touchesBegan:(NSSet<UITouch *> *)touches withEvent:(UIEvent *)event {
//    self.showsPlaybackControls = YES;
//    [super touchesBegan:touches withEvent:event];
//}
@end
