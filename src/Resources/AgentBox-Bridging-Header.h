// AgentBox Bridging Header — Swift ↔ ish-arm64 C/Obj-C
// 导入 ish-arm64 的核心头文件，使 Swift 代码可以直接调用

// 核心引擎
#include "kernel/init.h"
#include "kernel/calls.h"
#include "kernel/task.h"
#include "kernel/memory.h"

// 文件系统
#include "fs/devices.h"
#include "fs/real.h"
#include "fs/path.h"
#include "fs/fake.h"

// Shell 执行器（Agent API）
#import "ISHShellExecutor.h"

// 调试服务器（可选）
#import "DebugServer.h"

// 引擎互操作
#import "LinuxInterop.h"

// 根文件系统
#import "Roots.h"
#import "CurrentRoot.h"

// 应用组
#import "AppGroup.h"

// 引擎生命周期通知
extern NSString *const ProcessExitedNotification;
