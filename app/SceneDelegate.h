//
//  SceneDelegate.h
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import <UIKit/UIKit.h>
#import "TerminalViewController.h"

NS_ASSUME_NONNULL_BEGIN

// 可空: 桌面层没有打开任何终端窗口时为 NULL(Swift 侧 dismantle 会置空)。
extern TerminalViewController * _Nullable currentTerminalViewController;

API_AVAILABLE(ios(13))
@interface SceneDelegate : UIResponder <UIWindowSceneDelegate>

@property (nonatomic) UIWindow *window;

@end

NS_ASSUME_NONNULL_END
