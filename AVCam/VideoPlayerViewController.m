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

-(void)viewDidLoad {
    
    [super viewDidLoad];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSString *videoPath = [NSString stringWithFormat:@"%@/%@", documentsDirectory, self.filePath];
    NSURL *fileURL = [NSURL fileURLWithPath:videoPath];
    self.player = [AVPlayer playerWithURL:fileURL];
}
@end
