#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>
#import <QuartzCore/QuartzCore.h>

@interface WebRTCEncoder : NSObject

@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) CMVideoCodecType codecType;
@property (nonatomic, assign) int targetBitrate;
@property (nonatomic, assign) int targetFramerate;
@property (nonatomic, strong) NSMutableData *encodedData;

// Initialize with codec type (H.264, HEVC, etc.)
- (instancetype)initWithCodec:(CMVideoCodecType)codec 
                       width:(int)width 
                      height:(int)height 
                     bitrate:(int)bitrate 
                   framerate:(int)framerate;

// Encode a CVPixelBuffer to compressed data
- (NSData *)encodeFrame:(CVPixelBufferRef)pixelBuffer;

// Update encoding parameters dynamically
- (void)updateBitrate:(int)newBitrate;
- (void)updateFramerate:(int)newFramerate;

// Get current encoding stats
- (NSDictionary *)getEncodingStats;

// Cleanup
- (void)cleanup;

@end