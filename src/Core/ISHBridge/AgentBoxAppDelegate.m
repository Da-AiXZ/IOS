// AgentBoxAppDelegate.m
// AgentBox
//
//  Provides the ProcessExitedNotification constant and the agentbox_exit_hook
//  callback so ISHShellExecutor can react to process exits.
//

#import "AgentBoxAppDelegate.h"

#include "kernel/task.h"

// ---- Notification constant ----

NSString *const ProcessExitedNotification = @"ProcessExitedNotification";

// ---- Kernel exit hook ----

/// Called by the ish kernel (via exit_hook) whenever a guest process exits.
/// Posts ProcessExitedNotification so ISHShellExecutor can resume any
/// waiting completion blocks.
void agentbox_exit_hook(struct task *task, int code) {
    [[NSNotificationCenter defaultCenter]
        postNotificationName:ProcessExitedNotification
                      object:nil
                    userInfo:@{
        @"pid":  @(task->pid),
        @"code": @(code),
    }];
}
