//
//  DroneVideoView.h
//  DVC-MobileClient-iOS
//

#import <UIKit/UIKit.h>

@import AVFoundation;

@interface DroneVideoView : UIView

@property (nonatomic, retain) AVSampleBufferDisplayLayer *videoLayer;

-(void) updateVideoViewWithFrame:(uint8_t *)frame frameSize:(uint32_t)frameSize;

@end
