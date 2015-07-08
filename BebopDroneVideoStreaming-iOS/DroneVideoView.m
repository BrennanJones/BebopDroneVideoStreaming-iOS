//
//  DroneVideoView.m
//  DVC-MobileClient-iOS
//

#import <VideoToolbox/VTDecompressionSession.h>
#import "DroneVideoView.h"


static const NSString * naluTypesStrings[] = {
    @"Unspecified (non-VCL)",
    @"Coded slice of a non-IDR picture (VCL)",
    @"Coded slice data partition A (VCL)",
    @"Coded slice data partition B (VCL)",
    @"Coded slice data partition C (VCL)",
    @"Coded slice of an IDR picture (VCL)",
    @"Supplemental enhancement information (SEI) (non-VCL)",
    @"Sequence parameter set (non-VCL)",
    @"Picture parameter set (non-VCL)",
    @"Access unit delimiter (non-VCL)",
    @"End of sequence (non-VCL)",
    @"End of stream (non-VCL)",
    @"Filler data (non-VCL)",
    @"Sequence parameter set extension (non-VCL)",
    @"Prefix NAL unit (non-VCL)",
    @"Subset sequence parameter set (non-VCL)",
    @"Reserved (non-VCL)",
    @"Reserved (non-VCL)",
    @"Reserved (non-VCL)",
    @"Coded slice of an auxiliary coded picture without partitioning (non-VCL)",
    @"Coded slice extension (non-VCL)",
    @"Coded slice extension for depth view components (non-VCL)",
    @"Reserved (non-VCL)",
    @"Reserved (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
    @"Unspecified (non-VCL)",
};


@interface DroneVideoView ()

@property (nonatomic) BOOL searchForSPSAndPPS;

@property (nonatomic) NSData *spsData;
@property (nonatomic) NSData *ppsData;

@property (nonatomic) CMVideoFormatDescriptionRef videoFormatDescr;

@property (nonatomic) VTDecompressionSessionRef decompressionSession;

@end


@implementation DroneVideoView

- (void)commonInit {
    _searchForSPSAndPPS = true;
    
    [self setNeedsLayout];
    [self layoutIfNeeded];
    
    self.videoLayer = [[AVSampleBufferDisplayLayer alloc] init];
    self.videoLayer.bounds = self.bounds;
    self.videoLayer.position = CGPointMake(CGRectGetMidX(self.bounds), CGRectGetMidY(self.bounds));
    self.videoLayer.videoGravity = AVLayerVideoGravityResizeAspect;
    self.videoLayer.backgroundColor = [[UIColor blackColor] CGColor];
    
    // Set Timebase
    CMTimebaseRef controlTimebase;
    CMTimebaseCreateWithMasterClock( CFAllocatorGetDefault(), CMClockGetHostTimeClock(), &controlTimebase );
    
    self.videoLayer.controlTimebase = controlTimebase;
    CMTimebaseSetTime(self.videoLayer.controlTimebase, CMTimeMake(5, 1));
    CMTimebaseSetRate(self.videoLayer.controlTimebase, 1.0);
    
    // Connecting the videolayer with the view
    [[self layer] addSublayer:_videoLayer];
}


-(id) initWithCoder:(NSCoder *)aDecoder
{
    if (self = [super initWithCoder:aDecoder]) [self commonInit];
    return self;
}

-(id) initWithFrame:(CGRect)frame
{
    self = [super initWithFrame:frame];
    if (self) {
        // Initialization code
    }
    return self;
}

-(void) updateVideoViewWithFrame:(uint8_t *)frame frameSize:(uint32_t)frameSize
{
    //
    // Credit for a lot of this code goes to Zappel on Stack Overflow:
    //  (http://stackoverflow.com/questions/25980070/how-to-use-avsamplebufferdisplaylayer-in-ios-8-for-rtp-h264-streams-with-gstream)
    //
    
    int startCodeIndex = 0;
    for (int i = 0; i < 4; i++)
    {
        startCodeIndex = i + 1;
        if (frame[i] == 0x01)
        {
            break;
        }
    }
    int nalu_type = ((uint8_t)frame[startCodeIndex] & 0x1F);
    NSLog(@"NALU with Type \"%@\" received.", naluTypesStrings[nalu_type]);
    
    while (nalu_type == 7 || nalu_type == 8)
    {
        int endCodeIndex;
        int numConsecutiveZeros = 0;
        for (endCodeIndex = startCodeIndex; endCodeIndex < frameSize; endCodeIndex++)
        {
            if (frame[endCodeIndex] == 0x01 && numConsecutiveZeros == 3)
            {
                endCodeIndex -= 3;
                break;
            }
            
            if (frame[endCodeIndex] == 0x00)
            {
                numConsecutiveZeros++;
            }
            else
            {
                numConsecutiveZeros = 0;
            }
        }
        
        if(_searchForSPSAndPPS)
        {
            if (nalu_type == 7)
            {
                _spsData = [NSData dataWithBytes:&(frame[startCodeIndex]) length: endCodeIndex - startCodeIndex];
            }
            else // if (nalu_type == 8)
            {
                _ppsData = [NSData dataWithBytes:&(frame[startCodeIndex]) length: endCodeIndex - startCodeIndex];
            }
            
            if (_spsData != nil && _ppsData != nil)
            {
                const uint8_t* const parameterSetPointers[2] = { (const uint8_t*)[_spsData bytes], (const uint8_t*)[_ppsData bytes] };
                const size_t parameterSetSizes[2] = { [_spsData length], [_ppsData length] };
                
                OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault, 2, parameterSetPointers, parameterSetSizes, 4, &_videoFormatDescr);
                _searchForSPSAndPPS = false;
                NSLog(@"Found all data for CMVideoFormatDescription. Creation: %@.", (status == noErr) ? @"successfully." : @"failed.");
            }
        }
        
        startCodeIndex = endCodeIndex + 4;
        nalu_type = ((uint8_t)frame[startCodeIndex] & 0x1F);
        NSLog(@"NALU with Type \"%@\" received.", naluTypesStrings[nalu_type]);
    }
    
    frame = &frame[startCodeIndex];
    frameSize -= startCodeIndex;
    
    if (nalu_type == 1 || nalu_type == 5)
    {
        CMBlockBufferRef videoBlock = NULL;
        OSStatus status = CMBlockBufferCreateWithMemoryBlock(NULL, &frame[-4], frameSize+4, kCFAllocatorNull, NULL, 0, frameSize+4, 0, &videoBlock);
        NSLog(@"BlockBufferCreation: %@", (status == kCMBlockBufferNoErr) ? @"successfully." : @"failed.");
        
        const uint8_t sourceBytes[] = {(uint8_t)(frameSize >> 24), (uint8_t)(frameSize >> 16), (uint8_t)(frameSize >> 8), (uint8_t)frameSize};
        status = CMBlockBufferReplaceDataBytes(sourceBytes, videoBlock, 0, 4);
        NSLog(@"BlockBufferReplace: %@", (status == kCMBlockBufferNoErr) ? @"successfully." : @"failed.");
        
        CMSampleBufferRef sbRef = NULL;
        const size_t sampleSizeArray[] = {frameSize};
        
        status = CMSampleBufferCreate(kCFAllocatorDefault, videoBlock, true, NULL, NULL, _videoFormatDescr, 1, 0, NULL, 1, sampleSizeArray, &sbRef);
        NSLog(@"SampleBufferCreate: %@", (status == noErr) ? @"successfully." : @"failed.");
        
        CFArrayRef attachments = CMSampleBufferGetSampleAttachmentsArray(sbRef, YES);
        CFMutableDictionaryRef dict = (CFMutableDictionaryRef)CFArrayGetValueAtIndex(attachments, 0);
        CFDictionarySetValue(dict, kCMSampleAttachmentKey_DisplayImmediately, kCFBooleanTrue);
        
        NSLog(@"Error: %@, Status:%@", _videoLayer.error, (_videoLayer.status == AVQueuedSampleBufferRenderingStatusUnknown)?@"unknown":((_videoLayer.status == AVQueuedSampleBufferRenderingStatusRendering)?@"rendering":@"failed"));
        dispatch_async(dispatch_get_main_queue(),^{
            [_videoLayer enqueueSampleBuffer:sbRef];
            [_videoLayer setNeedsDisplay];
        });
    }
}

/*
// Only override drawRect: if you perform custom drawing.
// An empty implementation adversely affects performance during animation.
- (void)drawRect:(CGRect)rect {
    // Drawing code
}
*/

@end
