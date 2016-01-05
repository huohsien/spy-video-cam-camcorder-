//
//  CaptureVideosViewController.m
//  AVCam
//
//  Created by victor on 12/22/15.
//
//
#import "AVKit/AVkit.h"
#import "AVFoundation/AVFoundation.h"
#import "CaptureVideosViewController.h"
#import "VideoPlayerViewController.h"

#define TICK   NSDate *startTime = [NSDate date]
#define TOCK   NSLog(@"Time: %f", -[startTime timeIntervalSinceNow])

static NSString *const reuseIdentifier = @"videoClipCell";

@implementation NSArray (Reverse)

- (NSArray *)reversedArray {
    NSMutableArray *array = [NSMutableArray arrayWithCapacity:[self count]];
    NSEnumerator *enumerator = [self reverseObjectEnumerator];
    for (id element in enumerator) {
        [array addObject:element];
    }
    return array;
}
@end

@implementation NSMutableArray (Reverse)

- (void)reverse {
    if ([self count] <= 1)
        return;
    NSUInteger i = 0;
    NSUInteger j = [self count] - 1;
    while (i < j) {
        [self exchangeObjectAtIndex:i
                  withObjectAtIndex:j];
        
        i++;
        j--;
    }
}
@end
@implementation CaptureVideosViewController {
    NSUInteger numberOfVideoClips;
    NSMutableArray *filePathsArray;
    NSMutableArray *thumbnailArray;
    NSMutableArray *thumbnailAspectRatioArray;
    NSString *videoFilePathToBePlayed;
}

-(void)viewDidLoad {
    NSLog(@"%s", __PRETTY_FUNCTION__);
    
    [super viewDidLoad];
    
    numberOfVideoClips = 0;
    videoFilePathToBePlayed = nil;
    
    [self.navigationController setNavigationBarHidden:NO];
    self.navigationController.navigationBar.barStyle = UIBarStyleBlack;
    [self.collectionView registerClass:[UICollectionViewCell class] forCellWithReuseIdentifier:@"VideoClipsCell"];
    
    NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
    NSString *documentsDirectory = [paths objectAtIndex:0];
    
    NSArray *pathArray = [[NSFileManager defaultManager] subpathsOfDirectoryAtPath:documentsDirectory error:nil];
    filePathsArray = [NSMutableArray arrayWithArray:[pathArray reversedArray]];
    numberOfVideoClips = [filePathsArray count];
    
    thumbnailArray = [NSMutableArray new];
    thumbnailAspectRatioArray = [NSMutableArray new];
//    TICK;

    for (int i = 0; i < numberOfVideoClips; i++) {
        NSString *videoPath = [NSString stringWithFormat:@"%@/%@", documentsDirectory, [filePathsArray objectAtIndex:i]];
        NSURL *fileURL = [NSURL fileURLWithPath:videoPath];
        UIImage *image = [self thumbnailImageForVideo:fileURL atTime:0.0];
        [thumbnailArray addObject:image];
        CGFloat width = image.size.width;
        CGFloat height = image.size.height;

        [thumbnailAspectRatioArray addObject:[NSNumber numberWithDouble: width / height]];
    }
//    TOCK;

    
    UITapGestureRecognizer *tapGesture = [[UITapGestureRecognizer alloc] initWithTarget:self action:@selector(cellTapped:)];
    [tapGesture setNumberOfTapsRequired:1];
    [tapGesture setNumberOfTouchesRequired:1];
    [self.view addGestureRecognizer:tapGesture];
    
    UILongPressGestureRecognizer *longPressGesture = [[UILongPressGestureRecognizer alloc] initWithTarget:self action:@selector(longPressed:)];
    longPressGesture.minimumPressDuration = 0.4;
    [self.view addGestureRecognizer:longPressGesture];
    

}
#pragma mark - gesture recognizer callbacks

- (void) cellTapped:(UITapGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateEnded)
    {
        CGPoint point = [sender locationInView:self.collectionView];
        NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
        if (indexPath)
        {
            NSLog(@"cell %ld", (long)indexPath.row);
            videoFilePathToBePlayed = [filePathsArray objectAtIndex:indexPath.row];
            [self performSegueWithIdentifier:@"playVideo" sender:self];
        }
        else
        {
        }
    }
}

- (void) longPressed:(UITapGestureRecognizer *)sender
{
    if (sender.state == UIGestureRecognizerStateEnded)
    {
        CGPoint point = [sender locationInView:self.collectionView];
        NSIndexPath *indexPath = [self.collectionView indexPathForItemAtPoint:point];
        if (indexPath)
        {
            NSLog(@"cell %ld", (long)indexPath.row);
            NSString *filePath = [filePathsArray objectAtIndex:indexPath.row];
            
            // delete file
            NSArray *paths = NSSearchPathForDirectoriesInDomains(NSDocumentDirectory, NSUserDomainMask, YES);
            NSString *documentsDirectory = [paths objectAtIndex:0];
            NSString *path = [NSString stringWithFormat:@"%@/%@", documentsDirectory, filePath];
            NSError *error;
            BOOL success = [[NSFileManager defaultManager] removeItemAtPath:path error:&error];
            if (success) {
                NSLog(@"file: %@ was deleted", path);
                [thumbnailArray removeObjectAtIndex:indexPath.row];
                [thumbnailAspectRatioArray removeObjectAtIndex:indexPath.row];
                [filePathsArray removeObjectAtIndex:indexPath.row];
                numberOfVideoClips--;
                [self.collectionView reloadData];
            }
            else
            {
                NSLog(@"Could not delete file -:%@ ",[error localizedDescription]);
            }
        }

    }
}



- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([segue.identifier isEqualToString:@"playVideo"]) {
        VideoPlayerViewController *destViewController = segue.destinationViewController;
        destViewController.filePath = videoFilePathToBePlayed;
    }
}

#pragma mark - UICollectionView Datasource
- (NSInteger)collectionView:(UICollectionView *)view numberOfItemsInSection:(NSInteger)section {
    
    return numberOfVideoClips;
}
- (NSInteger)numberOfSectionsInCollectionView: (UICollectionView *)collectionView {
    return 1;
}
- (UICollectionViewCell *)collectionView:(UICollectionView *)cv cellForItemAtIndexPath:(NSIndexPath *)indexPath {
    
    UICollectionViewCell *cell = [cv dequeueReusableCellWithReuseIdentifier:@"VideoClipsCell" forIndexPath:indexPath];
    
    UIImageView *imageView = [[UIImageView alloc] initWithFrame:CGRectMake(0, 0, 70, 70 / [[thumbnailAspectRatioArray objectAtIndex:indexPath.row] doubleValue])];
    
    [cell addSubview:imageView];
    
    [imageView setImage:[thumbnailArray objectAtIndex:indexPath.row]];
    
    return cell;
}


#pragma mark - UICollectionViewDelegate
- (void)collectionView:(UICollectionView *)collectionView didSelectItemAtIndexPath:(NSIndexPath *)indexPath
{
    // TODO: Select Item
}
- (void)collectionView:(UICollectionView *)collectionView didDeselectItemAtIndexPath:(NSIndexPath *)indexPath {
    // TODO: Deselect item
}

#pragma mark – UICollectionViewDelegateFlowLayout

- (CGSize)collectionView:(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout sizeForItemAtIndexPath:(NSIndexPath *)indexPath {

    CGSize retval =  CGSizeMake(70, 70 / [[thumbnailAspectRatioArray objectAtIndex:indexPath.row] doubleValue]);
    return retval;
}

- (UIEdgeInsets)collectionView:
(UICollectionView *)collectionView layout:(UICollectionViewLayout*)collectionViewLayout insetForSectionAtIndex:(NSInteger)section {
    return UIEdgeInsetsMake(50, 20, 50, 20);
}

#pragma mark - tools

- (UIImage *)thumbnailImageForVideo:(NSURL *)videoURL
                             atTime:(NSTimeInterval)time
{
    
    AVURLAsset *asset = [[AVURLAsset alloc] initWithURL:videoURL options:nil];
    NSParameterAssert(asset);
    AVAssetImageGenerator *assetIG =
    [[AVAssetImageGenerator alloc] initWithAsset:asset];
    assetIG.appliesPreferredTrackTransform = YES;
    assetIG.apertureMode = AVAssetImageGeneratorApertureModeEncodedPixels;
    
    CGImageRef thumbnailImageRef = NULL;
    CFTimeInterval thumbnailImageTime = time;
    NSError *igError = nil;
    thumbnailImageRef =
    [assetIG copyCGImageAtTime:CMTimeMake(thumbnailImageTime, 60)
                    actualTime:NULL
                         error:&igError];
    
    if (!thumbnailImageRef)
        NSLog(@"thumbnailImageGenerationError %@", igError );
    
    UIImage *thumbnailImage = thumbnailImageRef
    ? [[UIImage alloc] initWithCGImage:thumbnailImageRef]
    : nil;
    
    return thumbnailImage;
}


@end
