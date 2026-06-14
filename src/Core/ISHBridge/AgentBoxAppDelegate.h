// AgentBoxAppDelegate.h
// AgentBox
//
//  Minimal AppDelegate replacement declaring ProcessExitedNotification
//  (originally defined in iSH AppDelegate.m). ISHShellExecutor listens for
//  this notification to detect when a guest process exits.
//

#import <Foundation/Foundation.h>

/// Posted when a guest process exits.  userInfo keys:
///   - @"pid"  (NSNumber)  — guest task PID
///   - @"code" (NSNumber)  — exit code
extern NSString *const ProcessExitedNotification;
