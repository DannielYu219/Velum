//
//  SceneDelegate.m
//  iSH
//
//  Created by Theodore Dubois on 10/26/19.
//

#import "SceneDelegate.h"
#import "AboutViewController.h"
#import "Velum-Swift.h"

TerminalViewController *currentTerminalViewController = NULL;

@interface SceneDelegate ()

@property NSString *terminalUUID;

@end

static NSString *const TerminalUUID = @"TerminalUUID";

@implementation SceneDelegate

- (void)scene:(UIScene *)scene willConnectToSession:(UISceneSession *)session options:(UISceneConnectionOptions *)connectionOptions {
    // The scene is no longer pointed at Terminal.storyboard (see Info.plist), so
    // UIKit does not auto-create the window — we create it here. The nil-guard also
    // keeps this correct if a storyboard-backed window is ever reintroduced.
    if (self.window == nil) {
        self.window = [[UIWindow alloc] initWithWindowScene:(UIWindowScene *) scene];
    }

    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        AboutViewController *avc = (AboutViewController *) vc.topViewController;
        avc.recoveryMode = YES;
        self.window.rootViewController = vc;
    } else {
        // SwiftUI desktop owns all layout. Host is a thin UIHostingController only.
        self.window.rootViewController = [VLMDesktopFactory makeRootViewController];
    }

    [self.window makeKeyAndVisible];
}


- (NSUserActivity *)stateRestorationActivityForScene:(UIScene *)scene {
    // Phase 0.3: no terminal session to restore at scene level.
    return [[NSUserActivity alloc] initWithActivityType:@"app.ish.scene"];
}

- (void)sceneDidBecomeActive:(UIScene *)scene {
    // Phase 0.3: rootViewController is now SwiftUI, not TerminalViewController.
    // currentTerminalViewController will be set when terminal is opened (Phase 0.4).
}

- (void)sceneWillResignActive:(UIScene *)scene {
    // Phase 0.3: no TerminalViewController at scene level anymore.
}

@end
