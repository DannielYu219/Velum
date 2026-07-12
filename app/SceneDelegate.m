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
    if ([NSUserDefaults.standardUserDefaults boolForKey:@"recovery"]) {
        UINavigationController *vc = [[UIStoryboard storyboardWithName:@"About" bundle:nil] instantiateInitialViewController];
        AboutViewController *avc = (AboutViewController *) vc.topViewController;
        avc.recoveryMode = YES;
        self.window.rootViewController = vc;
        return;
    }

    // Phase 0.3: replace TerminalViewController with SwiftUI desktop.
    self.window.rootViewController = [VLMDesktopFactory makeRootViewController];
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
