//
//  KernelObjCBridge.h
//  Velum
//
//  Swift ↔ Obj-C bridge for the iSH kernel lifecycle.
//  The actual boot still runs in AppDelegate.m (synchronous, in willFinishLaunching),
//  this bridge only exposes status/query hooks to Swift.
//

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/// Kernel lifecycle state, mirrored from the Swift `Kernel.State` enum.
typedef NS_ENUM(NSInteger, VLMKernelState) {
    VLMKernelStateUnbooted = 0,
    VLMKernelStateBooting  = 1,
    VLMKernelStateReady    = 2,
    VLMKernelStateFailed   = 3,
};

/// Posted on the main queue whenever the boot state changes, so the Swift
/// `Kernel` observer can refresh without a polling timer.
extern NSString *const VLMKernelStateDidChangeNotification;

/// Pure Obj-C facade over the iSH boot path. Swift talks to this through the
/// bridging header; it never calls iSH C symbols directly.
///
/// Lifecycle:
///   1. AppDelegate calls `+sharedInstance` and `setPendingBoot` at willFinishLaunching start
///   2. AppDelegate calls `recordBootSuccess` / `recordBootFailure:` when `-boot` returns
///   3. Swift `Kernel` observes `VLMKernelStateDidChangeNotification`, then reads `currentState` / `bootError`
@interface KernelObjCBridge : NSObject

+ (instancetype)sharedInstance;

/// Called by AppDelegate at the very beginning of boot.
- (void)setPendingBoot;

/// Called by AppDelegate when `-boot` returned 0.
- (void)recordBootSuccess;

/// Called by AppDelegate when `-boot` returned non-zero (error).
- (void)recordBootFailure:(NSError *)error;

/// Read by Swift `Kernel` after a state-change notification.
@property (nonatomic, readonly) VLMKernelState currentState;

/// Non-nil if `currentState == VLMKernelStateFailed`.
@property (nonatomic, readonly, nullable) NSError *bootError;

@end

NS_ASSUME_NONNULL_END
