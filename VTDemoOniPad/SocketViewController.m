//
//  ViewController.m
//  VTDemoOniPad
//
//  Created by AJB on 16/4/25.
//  Copyright © 2016年 AJB. All rights reserved.
//

#import "SocketViewController.h"
#import <SocketRocket/SRWebSocket.h>
// 解码
#import "AAPLEAGLLayer.h"
#import <VideoToolbox/VideoToolbox.h>
AAPLEAGLLayer *_glLayer; // player
@interface SocketViewController ()
{
    // 解码
    uint8_t *_sps;
    NSInteger _spsSize;
    uint8_t *_pps;
    NSInteger _ppsSize;
    VTDecompressionSessionRef _deocderSession;
    CMVideoFormatDescriptionRef _decoderFormatDescription;
    
    NSThread* thread;
    NSLock* lock;
}

@property (weak, nonatomic) IBOutlet UIButton *startStopBtn;
@property (weak, nonatomic) IBOutlet UIButton *playerBtn;

@end

// 解码
static void didDecompress( void *decompressionOutputRefCon, void *sourceFrameRefCon, OSStatus status, VTDecodeInfoFlags infoFlags, CVImageBufferRef pixelBuffer, CMTime presentationTimeStamp, CMTime presentationDuration ){
    
    CVPixelBufferRef *outputPixelBuffer = (CVPixelBufferRef *)sourceFrameRefCon;
    *outputPixelBuffer = CVPixelBufferRetain(pixelBuffer);
    if(pixelBuffer) {
        _glLayer.pixelBuffer = pixelBuffer;
        CVPixelBufferRelease(pixelBuffer);
    }
    
}

static const uint8_t *avc_find_startcode_internal(const uint8_t *p, const uint8_t *end)
{
    const uint8_t *a = p + 4 - ((intptr_t)p & 3);
    
    for (end -= 3; p < a && p < end; p++) {
        if (p[0] == 0 && p[1] == 0 && p[2] == 1)
            return p;
    }
    
    for (end -= 3; p < end; p += 4) {
        uint32_t x = *(const uint32_t*)p;
        if ((x - 0x01010101) & (~x) & 0x80808080) { // generic
            if (p[1] == 0) {
                if (p[0] == 0 && p[2] == 1)
                    return p;
                if (p[2] == 0 && p[3] == 1)
                    return p+1;
            }
            if (p[3] == 0) {
                if (p[2] == 0 && p[4] == 1)
                    return p+2;
                if (p[4] == 0 && p[5] == 1)
                    return p+3;
            }
        }
    }
    
    for (end += 3; p < end; p++) {
        if (p[0] == 0 && p[1] == 0 && p[2] == 1)
            return p;
    }
    
    return end + 3;
}

const uint8_t *avc_find_startcode(const uint8_t *p, const uint8_t *end)
{
    const uint8_t *out= avc_find_startcode_internal(p, end);
    if(p<out && out<end && !out[-1]) out--;
    return out;
}

@implementation SocketViewController

//初始化
- (void)Reconnect{
    self.webSocket.delegate = nil;
    [self.webSocket close];
    
    self.webSocket = [[SRWebSocket alloc] initWithURLRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"ws://test.ms.happywawa.cn:8778/"]]];
    self.webSocket.delegate = self;
    
    self.title = @"Opening Connection...";
    
    [self.webSocket open];
    
}

//成功连接
- (void)webSocketDidOpen:(SRWebSocket *)webSocket {
    NSLog(@"Websocket Connected");
    NSMutableDictionary* dic = [NSMutableDictionary dictionaryWithObjectsAndKeys:@"2",@"wawaji_id",@"1",@"cam_id", nil];
    //        this.send( JSON.stringify( { uid: options.uid, session_id: options.session_id, wawaji_id: options.wawaji_id, cam_id: options.cam_id} ) );
    [self.webSocket send:[self DataTOjsonString:dic]];
    // 解码
    //    _glLayer = [[AAPLEAGLLayer alloc] initWithFrame:CGRectMake(0, 20, self.view.frame.size.width, (self.view.frame.size.width * 9)/16 )] ;
    _glLayer = [[AAPLEAGLLayer alloc] initWithFrame:CGRectMake(0, 20, 300, 400 )] ;
    [self.view.layer addSublayer:_glLayer];
    
    
}
//连接失败，打印错误信息
- (void)webSocket:(SRWebSocket *)webSocket didFailWithError:(NSError *)error {
    NSLog(@":( Websocket Failed With Error %@", error);
    self.title = @"Connection Failed! (see logs)";
    self.webSocket = nil;
    // 断开连接后每过1s重新建立一次连接
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [self Reconnect];
    });
}

//接收服务器发送信息
- (void)webSocket:(SRWebSocket *)webSocket didReceiveMessage:(id)message {
    NSData* data = (NSData*)message;
    [self decodeFile:data];
    [NSThread sleepForTimeInterval:0.005];
    
}

// 长连接关闭
- (void)webSocket:(SRWebSocket *)webSocket didCloseWithCode:(NSInteger)code reason:(NSString *)reason wasClean:(BOOL)wasClean {
    NSLog(@"WebSocket closed");
    self.title = @"Connection Closed! (see logs)";
    self.webSocket = nil;
    [self clearH264Deocder];
}
//该函数是接收服务器发送的pong消息
- (void)webSocket:(SRWebSocket *)webSocket didReceivePong:(NSData *)pongPayload {
    NSString *reply = [[NSString alloc] initWithData:pongPayload encoding:NSUTF8StringEncoding];
    NSLog(@"%@",reply);
}

- (void)viewDidLoad {
    [super viewDidLoad];
    //socket
    lock = [NSLock alloc];
    thread = [[NSThread alloc] initWithTarget:self selector:@selector(Reconnect) object:nil];
    [thread start];
}

#pragma mark - 解码
-(BOOL)initH264Decoder {
    if(_deocderSession) {
        return YES;
    }
    
    if (!_sps || !_pps || _spsSize == 0 || _ppsSize == 0) {
        return NO;
    }
    
    const uint8_t* const parameterSetPointers[2] = { _sps, _pps };
    const size_t parameterSetSizes[2] = { _spsSize, _ppsSize };
    OSStatus status = CMVideoFormatDescriptionCreateFromH264ParameterSets(kCFAllocatorDefault,
                                                                          2, //param count
                                                                          parameterSetPointers,
                                                                          parameterSetSizes,
                                                                          4, //nal start code size
                                                                          &_decoderFormatDescription);
    
    if(status == noErr) {
        CFDictionaryRef attrs = NULL;
        const void *keys[] = { kCVPixelBufferPixelFormatTypeKey };
        //      kCVPixelFormatType_420YpCbCr8Planar is YUV420
        //      kCVPixelFormatType_420YpCbCr8BiPlanarFullRange is NV12
        uint32_t v = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange;
        const void *values[] = { CFNumberCreate(NULL, kCFNumberSInt32Type, &v) };
        attrs = CFDictionaryCreate(NULL, keys, values, 1, NULL, NULL);
        
        NSDictionary* destinationPixelBufferAttributes = @{
                                                           (id)kCVPixelBufferPixelFormatTypeKey : [NSNumber numberWithInt:kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange]
                                                           //硬解必须是 kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange 或者是kCVPixelFormatType_420YpCbCr8Planar
                                                           //因为iOS是nv12  其他是nv21
                                                           , (id)kCVPixelBufferWidthKey  : [NSNumber numberWithInt:600]
                                                           , (id)kCVPixelBufferHeightKey : [NSNumber numberWithInt:800]
                                                           //, (id)kCVPixelBufferBytesPerRowAlignmentKey : [NSNumber numberWithInt:kH264outputWidth*2]
                                                           , (id)kCVPixelBufferOpenGLCompatibilityKey : [NSNumber numberWithBool:NO]
                                                           , (id)kCVPixelBufferOpenGLESCompatibilityKey : [NSNumber numberWithBool:YES]
                                                           };
        
        VTDecompressionOutputCallbackRecord callBackRecord;
        callBackRecord.decompressionOutputCallback = didDecompress;
        callBackRecord.decompressionOutputRefCon = (__bridge void *)self;
        
        status = VTDecompressionSessionCreate(kCFAllocatorDefault,
                                              _decoderFormatDescription,
                                              NULL, (__bridge CFDictionaryRef)destinationPixelBufferAttributes,
                                              &callBackRecord,
                                              &_deocderSession);
        VTSessionSetProperty(_deocderSession, kVTDecompressionPropertyKey_ThreadCount, (__bridge CFTypeRef)[NSNumber numberWithInt:1]);
        VTSessionSetProperty(_deocderSession, kVTDecompressionPropertyKey_RealTime, kCFBooleanTrue);
        CFRelease(attrs);
    } else {
        NSLog(@"IOS8VT: reset decoder session failed status=%d", (int)status);
    }
    
    return YES;
}
-(void)clearH264Deocder {
    if(_deocderSession) {
        VTDecompressionSessionInvalidate(_deocderSession);
        CFRelease(_deocderSession);
        _deocderSession = NULL;
    }
    
    if(_decoderFormatDescription) {
        CFRelease(_decoderFormatDescription);
        _decoderFormatDescription = NULL;
    }
    
    free(_sps);
    free(_pps);
    _spsSize = _ppsSize = 0;
    
    if (thread != nil) {
        if (!thread.isCancelled) {
            [thread cancel];
        }
    }
}

-(uint8_t*)uint8FromBytes:(NSData *)fData buffer:(uint8_t*)frame
{
    //NSAssert(fData.length == 1, @"uint8FromBytes: (data length != 1)");
    NSData *data = fData;
    uint8_t* val = NULL;
    [data getBytes:&frame length:data.length];
    return val;
}

- (CVPixelBufferRef)decode:(uint8_t *)frame withSize:(uint32_t)frameSize {
    if (frame == NULL || _deocderSession == nil)
        return NULL;
    
    CVPixelBufferRef outputPixelBuffer = NULL;
    CMBlockBufferRef blockBuffer = NULL;
    
    OSStatus status  = CMBlockBufferCreateWithMemoryBlock(NULL,
                                                          (void *)frame,
                                                          frameSize,
                                                          kCFAllocatorNull,
                                                          NULL,
                                                          0,
                                                          frameSize,
                                                          FALSE,
                                                          &blockBuffer);
    if(status == kCMBlockBufferNoErr) {
        CMSampleBufferRef sampleBuffer = NULL;
        const size_t sampleSizeArray[] = {frameSize};
        //        status = CMSampleBufferCreateReady(kCFAllocatorDefault,
        //                                           blockBuffer,
        //                                           _decoderFormatDescription ,
        //                                           1, 0, NULL, 1, sampleSizeArray,
        //                                           &sampleBuffer);
        status = CMSampleBufferCreate(NULL, blockBuffer, TRUE, 0, 0, _decoderFormatDescription, 1, 0, NULL, 0, NULL, &sampleBuffer);
        
        if (status == kCMBlockBufferNoErr && sampleBuffer) {
            VTDecodeFrameFlags flags = 0;
            VTDecodeInfoFlags flagOut = 0;
            status = VTDecompressionSessionDecodeFrame(_deocderSession,
                                                       sampleBuffer,
                                                       flags,
                                                       &outputPixelBuffer,
                                                       &flagOut);
            
            if (status == kVTInvalidSessionErr) {
                NSLog(@"Invalid session, reset decoder session");
                [self resetH264Decoder];
            } else if(status == kVTVideoDecoderBadDataErr) {
                NSLog(@"decode failed status=%d(Bad data)", status);
            } else if(status != noErr) {
                NSLog(@"decode failed status=%d", status);
            }
        }
        
        if (sampleBuffer != NULL)
            CFRelease(sampleBuffer);
    }
    if (blockBuffer != NULL)
        CFRelease(blockBuffer);
    
    return outputPixelBuffer;
}

- (BOOL)resetH264Decoder {
    if(_deocderSession) {
        VTDecompressionSessionWaitForAsynchronousFrames(_deocderSession);
        VTDecompressionSessionInvalidate(_deocderSession);
        CFRelease(_deocderSession);
        _deocderSession = NULL;
    }
    return [self initH264Decoder];
}

-(void)decodeFile:(NSData*)data {
    NSData *vp = nil;
    [lock lock];
    uint8_t *_buf_out = (uint8_t*)malloc(1080 * 1920 * sizeof(uint8_t));
    
    vp = data;
    uint8_t* frame = (uint8_t*)vp.bytes;
    uint32_t frameSize = (uint32_t)vp.length;
    if (frame != NULL)
    {
        int size = frameSize;
        const uint8_t *p = frame;
        const uint8_t *end = p + size;
        const uint8_t *nal_start, *nal_end;
        int nal_len, nalu_type = 0;
        
        size = 0;
        nal_start = avc_find_startcode(p, end);
        while (![[NSThread currentThread] isCancelled]) {
            while (![[NSThread currentThread] isCancelled] && nal_start < end && !*(nal_start++));
            if (nal_start == end)
                break;
            
            nal_end = avc_find_startcode(nal_start, end);
            nal_len = nal_end - nal_start;
            
            nalu_type = nal_start[0] & 0x1f;
            if (nalu_type == 0x07) {
                if (_sps == NULL) {
                    _spsSize = nal_len;
                    _sps = (uint8_t*)malloc(_spsSize);
                    memcpy(_sps, nal_start, _spsSize);
                    NSLog(@"Nal type is SPS");
                }
            }
            else if (nalu_type == 0x08) {
                if (_pps == NULL) {
                    _ppsSize = nal_len;
                    _pps = (uint8_t*)malloc(_ppsSize);
                    memcpy(_pps, nal_start, _ppsSize);
                    NSLog(@"Nal type is PPS");
                }
            }
            else {
                NSLog(@"Nal type is %d",nalu_type);
                _buf_out[size + 0] = (uint8_t)(nal_len >> 24);
                _buf_out[size + 1] = (uint8_t)(nal_len >> 16);
                _buf_out[size + 2] = (uint8_t)(nal_len >> 8 );
                _buf_out[size + 3] = (uint8_t)(nal_len);
                
                memcpy(_buf_out + 4 + size, nal_start, nal_len);
                size += 4 + nal_len;
            }
            
            nal_start = nal_end;
        }
        
        if ([self initH264Decoder]) {
            CVPixelBufferRef pixelBuffer = NULL;
            pixelBuffer = [self decode:_buf_out withSize:size];
        }
    }
    [lock unlock];
    if (_sps != NULL) {
        free(_sps);
        _sps = NULL;
        _spsSize = 0;
    }
    
    if (_pps != NULL) {
        free(_pps);
        _pps = NULL;
        _ppsSize = 0;
    }
    if (_buf_out != NULL) {
        free(_buf_out);
        _buf_out = NULL;
    }
}

-(NSString*)DataTOjsonString:(id)object
{
    NSString *jsonString = nil;
    NSError *error;
    NSData *jsonData = [NSJSONSerialization dataWithJSONObject:object
                                                       options:NSJSONWritingPrettyPrinted // Pass 0 if you don't care about the readability of the generated string
                                                         error:&error];
    if (! jsonData) {
        NSLog(@"Got an error: %@", error);
    } else {
        jsonString = [[NSString alloc] initWithData:jsonData encoding:NSUTF8StringEncoding];
    }
    return jsonString;
}

#pragma mark - 编码
// Called when start/stop button is pressed
- (IBAction)StopAction:(id)sender {
    
    // Close WebSocket
    self.webSocket.delegate = nil;
    [self.webSocket close];
    self.webSocket = nil;
}

- (void)statusBarOrientationDidChange:(NSNotification*)notification {
    //[self setRelativeVideoOrientation];
}

@end
