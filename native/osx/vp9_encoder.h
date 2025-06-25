#import <Foundation/Foundation.h>
#import <VideoToolbox/VideoToolbox.h>
#import <CoreMedia/CoreMedia.h>
#import <CoreVideo/CoreVideo.h>

@interface VP9Encoder : NSObject

@property (nonatomic, assign) VTCompressionSessionRef compressionSession;
@property (nonatomic, assign) int width;
@property (nonatomic, assign) int height;
@property (nonatomic, assign) int bitrate;
@property (nonatomic, assign) int framerate;
@property (nonatomic, strong) NSMutableData *encodedData;
@property (nonatomic, strong) void (^frameCallback)(NSData *encodedFrame);

- (instancetype)initWithWidth:(int)width 
                       height:(int)height 
                      bitrate:(int)bitrate 
                    framerate:(int)framerate;

- (BOOL)encodeFrame:(CVPixelBufferRef)pixelBuffer;
- (void)setFrameCallback:(void (^)(NSData *encodedFrame))callback;
- (void)forceKeyFrame;

@end