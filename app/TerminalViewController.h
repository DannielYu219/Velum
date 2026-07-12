//
//  ViewController.h
//  iSH
//
//  Created by Theodore Dubois on 10/17/17.
//

#import <UIKit/UIKit.h>
#import "Terminal.h"

@interface TerminalViewController : UIViewController

@property (nonatomic) Terminal *terminal;

// Velum: exposed so the SwiftUI wrapper (TerminalView.swift) can force-set this
// to YES on iPad with an external keyboard, hiding the extra-keys bar (esc/tab/
// ctrl/...) from the very first frame — no flash on terminal open.
@property (nonatomic) BOOL hasExternalKeyboard;

- (void)startNewSession;
- (void)reconnectSessionFromTerminalUUID:(NSUUID *)uuid;
@property (readonly) NSUUID *sessionTerminalUUID; // 0 means invalid
@property UISceneSession *sceneSession API_AVAILABLE(ios(13.0));

@end

extern struct tty_driver ios_tty_driver;
