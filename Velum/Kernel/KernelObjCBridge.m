//
//  KernelObjCBridge.m
//  Velum
//
//  Implements the bridge. Keeps a tiny state machine that AppDelegate drives
//  and Swift reads. Thread-safe via @synchronized (state can flip from the
//  main thread during willFinishLaunching while Swift reads it later).
//

#import "KernelObjCBridge.h"

@implementation KernelObjCBridge {
    VLMKernelState _state;
    NSError *_error;
}

+ (instancetype)sharedInstance {
    static KernelObjCBridge *instance;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{
        instance = [[KernelObjCBridge alloc] init];
    });
    return instance;
}

- (instancetype)init {
    self = [super init];
    if (self) {
        _state = VLMKernelStateUnbooted;
        _error = nil;
    }
    return self;
}

- (void)setPendingBoot {
    @synchronized(self) {
        _state = VLMKernelStateBooting;
    }
}

- (void)recordBootSuccess {
    @synchronized(self) {
        _state = VLMKernelStateReady;
        _error = nil;
    }
}

- (void)recordBootFailure:(NSError *)error {
    @synchronized(self) {
        _state = VLMKernelStateFailed;
        _error = error;
    }
}

- (VLMKernelState)currentState {
    @synchronized(self) {
        return _state;
    }
}

- (NSError *)bootError {
    @synchronized(self) {
        return _error;
    }
}

@end
