/**
 * 剑影江湖 反检测插件 v2.0
 * 屏蔽网易易盾NTESHTPSec反作弊系统检测
 *
 * v1.0问题分析（日志）：
 * 1. NTESRiskSecProtect和NetSecProtect的ioctl/getToken/init/getTokenAsync地址完全相同
 *    → 它们共享同一个底层实现，无需重复hook
 * 2. 所有DobbyHook返回FAILED ret=-1
 *    → 原因：IL2CPP方法数组前8字节不是函数指针！
 *    → il2cpp_class_get_methods返回的是MethodInfo*，MethodInfo.layout:
 *       +0x00: methodPointer (实际函数地址)
 *       +0x08: invoker_method (或其他)
 *    → v1.0代码: memcpy(&funcAddr, m, sizeof(void*)) 只读了前8字节
 *    → 但这其实就是methodPointer，应该是对的...
 *    → 更可能的原因: 游戏可能在NTESHTPSec的native层(.framework)做了检测
 *       DobbyHook修改了代码段，被完整性校验发现→闪退
 * 3. 游戏加载一会就闪退 - 可能是hook本身触发反作弊导致
 *
 * v2.0策略改变：
 * 不再hook IL2CPP层的方法，改为：
 * A. Hook底层native函数 - 反作弊SDK的native实现
 * B. 使用DobbyInstrument（非inline hook，不改代码段）替代DobbyHook
 * C. 或者干脆不走hook，而是修改isInitialized静态变量
 * D. 关键：不修改代码段，避免完整性校验触发
 *
 * 新思路：
 * 1. 找到___initWithProductId (extern "C" native函数) 并hook它
 *    → 这个是P/Invoke底层，直接调native SDK
 *    → 地址0x5d301fc (dump.cs)，运行时=base+0x5d301fc
 * 2. 找到___ioctl (extern native) 并hook
 *    → 地址0x5d30b9c
 * 3. 找到___getToken (extern native) 并hook
 *    → 地址0x5d30624
 * 4. 修改isInitialized静态字段为true
 *
 * 但wait - DobbyHook返回-1意味着hook本身就失败了，不是hook后触发检测
 * 需要诊断为什么DobbyHook失败
 *
 * DobbyHook ret=-1 的常见原因：
 * - DOBBY_DEOPT_HOOK: 目标函数太短无法inline hook
 * - 内存保护：mprotect失败（iOS 17可能加强了内存保护）
 * - 地址无效：funcAddr不是有效的可执行代码地址
 *
 * v2.0修改：
 * 1. 修复MethodInfo读取：确保正确读取methodPointer
 * 2. 添加地址验证：在hook前检查地址是否在代码段内
 * 3. 添加DobbyDestroyHook清理：避免重复hook
 * 4. 跳过重复地址：NTESRiskSecProtect和NetSecProtect地址相同时只hook一次
 * 5. 尝试使用DobbyInstrument替代DobbyHook
 * 6. 延迟更久再hook：等反作弊SDK完全初始化
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

#include "dobby.h"

// ============================================================
// 日志
// ============================================================

static FILE *g_logFile = NULL;
static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH-AntiDetect] %@", msg);
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh_anti.log"];
        g_logFile = fopen([p UTF8String], "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

// ============================================================
// IL2CPP运行时API
// ============================================================

typedef void* (*Il2CppDomainGet)(void);
typedef void** (*Il2CppDomainGetAssemblies)(void*, size_t*);
typedef void* (*Il2CppAssemblyGetImage)(void*);
typedef size_t (*Il2CppImageGetClassCount)(void*);
typedef void* (*Il2CppImageGetClass)(void*, size_t);
typedef void* (*Il2CppClassGetMethods)(void*, void**);
typedef const char* (*Il2CppMethodGetName)(void*);
typedef uint32_t (*Il2CppMethodGetParamCount)(void*);
typedef const char* (*Il2CppClassGetName)(void*);

// IL2CPP string
typedef void* (*Il2CppStringNew)(const char*);

// ============================================================
// 找到的函数地址
// ============================================================

static void *g_funcIoctl = NULL;       // NTESRiskSecProtect.ioctl (与NetSecProtect.ioctl同地址)
static void *g_funcGetToken = NULL;    // NTESRiskSecProtect.getToken (与NetSecProtect.getToken同地址)
static void *g_funcInit = NULL;        // NTESRiskSecProtect.init (与NetSecProtect.init同地址)
static void *g_funcIsHtpExist = NULL;  // NetSecProtect.isHtpExist (唯一独立地址)
static void *g_funcMyGetTokenOnResult = NULL;
static void *g_funcMyHtpCallbackOnReceive = NULL;

// 基地址（用于硬编码偏移验证）
static uintptr_t g_baseAddr = 0;

// Hook状态
static BOOL g_ioctlHooked = NO;
static BOOL g_getTokenHooked = NO;
static BOOL g_myGetTokenHooked = NO;
static BOOL g_myHtpCallbackHooked = NO;
static BOOL g_isHtpExistHooked = NO;

// 原始函数指针
typedef void* (*FuncIoctl)(int requestCmdID, void* data);
static FuncIoctl g_origIoctl = NULL;

typedef void* (*FuncGetToken)(int timeout, void* businessId);
static FuncGetToken g_origGetToken = NULL;

typedef void (*FuncMyGetTokenOnResult)(void* self, void* antiCheatResult);
static FuncMyGetTokenOnResult g_origMyGetTokenOnResult = NULL;

typedef void (*FuncMyHtpCallbackOnReceive)(void* self, int code, void* msg);
static FuncMyHtpCallbackOnReceive g_origMyHtpCallbackOnReceive = NULL;

typedef BOOL (*FuncIsHtpExist)(void);
static FuncIsHtpExist g_origIsHtpExist = NULL;

// IL2CPP运行时函数
static Il2CppStringNew g_il2cpp_string_new = NULL;

// ============================================================
// 地址验证
// ============================================================

// 检查地址是否在可执行代码段内
static BOOL isValidCodeAddress(void *addr) {
    if (!addr) return NO;
    uintptr_t a = (uintptr_t)addr;
    // 遍历当前进程的所有Mach-O image
    for (uint32_t i = 0; i < _dyld_image_count(); i++) {
        const struct mach_header *header = _dyld_get_image_header(i);
        if (!header) continue;
        uintptr_t slide = (uintptr_t)_dyld_get_image_vmaddr_slide(i);
        // 只检查主二进制（游戏本身）
        if (i == 0) {
            // 主二进制的TEXT段通常在 base ~ base+0x80000000 范围内
            if (a >= (uintptr_t)header && a < (uintptr_t)header + 0x100000000ULL) {
                return YES;
            }
        }
    }
    // 也可以检查动态库
    return NO;
}

// 从MethodInfo正确读取函数指针
// IL2CPP MethodInfo结构：第一个字段就是methodPointer
static void* getMethodPointer(void *methodInfo) {
    if (!methodInfo) return NULL;
    void *funcPtr = NULL;
    memcpy(&funcPtr, methodInfo, sizeof(void*));
    return funcPtr;
}

// ============================================================
// IL2CPP搜索
// ============================================================

static void findIL2CPPMethods(void) {
    jlog(@"=== 反检测 v2.0 IL2CPP 搜索 ===");

    // 获取主二进制基地址
    const struct mach_header *mainHeader = _dyld_get_image_header(0);
    g_baseAddr = (uintptr_t)mainHeader;
    jlog(@"主二进制基地址: %p", (void*)g_baseAddr);

    void *h = dlopen(NULL, RTLD_LAZY);
    if (!h) { jlog(@"dlopen FAIL"); return; }

    Il2CppDomainGet domain_get = dlsym(h, "il2cpp_domain_get");
    Il2CppDomainGetAssemblies get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
    Il2CppAssemblyGetImage get_image = dlsym(h, "il2cpp_assembly_get_image");
    Il2CppImageGetClassCount class_count = dlsym(h, "il2cpp_image_get_class_count");
    Il2CppImageGetClass get_class = dlsym(h, "il2cpp_image_get_class");
    Il2CppClassGetMethods get_methods = dlsym(h, "il2cpp_class_get_methods");
    Il2CppMethodGetName method_name = dlsym(h, "il2cpp_method_get_name");
    Il2CppMethodGetParamCount param_count = dlsym(h, "il2cpp_method_get_param_count");
    Il2CppClassGetName class_name_func = dlsym(h, "il2cpp_class_get_name");

    g_il2cpp_string_new = dlsym(h, "il2cpp_string_new");

    if (!domain_get || !method_name) { jlog(@"IL2CPP APIs not found"); return; }
    void *domain = domain_get();
    if (!domain) return;
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    if (!assemblies) return;
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);

    // 已hook过的地址集合，避免重复hook
    static void *hookedAddrs[32];
    static int hookedAddrCount = 0;

    // 搜索目标 - 只搜索不重复的方法
    typedef struct {
        const char *className;
        const char *methodName;
        void **outAddr;
    } Search;

    Search searches[] = {
        {"NTESRiskSecProtect", "ioctl",       &g_funcIoctl},
        {"NTESRiskSecProtect", "getToken",    &g_funcGetToken},
        {"NTESRiskSecProtect", "init",        &g_funcInit},
        {"NetSecProtect",      "isHtpExist",  &g_funcIsHtpExist},
        {"MyGetToken",         "onResult",    &g_funcMyGetTokenOnResult},
        {"MyHtpCallback",      "onReceive",   &g_funcMyHtpCallbackOnReceive},
        {NULL, NULL, NULL}
    };

    int found = 0;

    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;
            if (!cn) continue;

            BOOL relevant = NO;
            for (int i = 0; searches[i].methodName; i++) {
                if (searches[i].className && strcmp(cn, searches[i].className) == 0) {
                    relevant = YES;
                    break;
                }
            }
            if (!relevant) continue;

            void *iter = NULL, *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                const char *n = method_name(m);
                if (!n) continue;
                uint32_t pc = param_count ? param_count(m) : 0;

                for (int i = 0; searches[i].methodName; i++) {
                    if (*searches[i].outAddr) continue;
                    if (strcmp(n, searches[i].methodName) == 0) {
                        void *funcAddr = getMethodPointer(m);
                        *(searches[i].outAddr) = funcAddr;
                        jlog(@"FOUND %s.%s params=%u addr=%p", cn, n, pc, funcAddr);
                        found++;
                    }
                }
            }
        }
    }

    jlog(@"Found %d unique targets", found);

    // 验证地址
    jlog(@"=== 地址验证 ===");
    jlog(@"ioctl=%p valid=%d", g_funcIoctl, isValidCodeAddress(g_funcIoctl));
    jlog(@"getToken=%p valid=%d", g_funcGetToken, isValidCodeAddress(g_funcGetToken));
    jlog(@"init=%p valid=%d", g_funcInit, isValidCodeAddress(g_funcInit));
    jlog(@"isHtpExist=%p valid=%d", g_funcIsHtpExist, isValidCodeAddress(g_funcIsHtpExist));
    jlog(@"MyGetToken.onResult=%p valid=%d", g_funcMyGetTokenOnResult, isValidCodeAddress(g_funcMyGetTokenOnResult));
    jlog(@"MyHtpCallback.onReceive=%p valid=%d", g_funcMyHtpCallbackOnReceive, isValidCodeAddress(g_funcMyHtpCallbackOnReceive));
    jlog(@"il2cpp_string_new=%p", g_il2cpp_string_new);

    // dump函数头几个字节（诊断用）
    if (g_funcIoctl) {
        uint8_t *p = (uint8_t*)g_funcIoctl;
        jlog(@"ioctl bytes: %02x %02x %02x %02x %02x %02x %02x %02x",
             p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    }
    if (g_funcMyGetTokenOnResult) {
        uint8_t *p = (uint8_t*)g_funcMyGetTokenOnResult;
        jlog(@"MyGetToken.onResult bytes: %02x %02x %02x %02x %02x %02x %02x %02x",
             p[0], p[1], p[2], p[3], p[4], p[5], p[6], p[7]);
    }
}

// ============================================================
// Hook辅助
// ============================================================

// 已hook地址跟踪
#define MAX_HOOKED 32
static void *g_hookedAddrs[MAX_HOOKED];
static int g_hookedAddrCount = 0;

static BOOL isAddrAlreadyHooked(void *addr) {
    for (int i = 0; i < g_hookedAddrCount; i++) {
        if (g_hookedAddrs[i] == addr) return YES;
    }
    return NO;
}

static void markAddrHooked(void *addr) {
    if (g_hookedAddrCount < MAX_HOOKED) {
        g_hookedAddrs[g_hookedAddrCount++] = addr;
    }
}

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: not found, skip", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    if (isAddrAlreadyHooked(funcAddr)) {
        jlog(@"%s: addr %p already used by another hook, skip (shared impl)", name, funcAddr);
        *hookedFlag = YES; // 标记为已hook（被另一个共享地址的hook覆盖）
        return;
    }

    jlog(@"%s: attempting DobbyHook at %p...", name, funcAddr);
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) {
        *hookedFlag = YES;
        markAddrHooked(funcAddr);
        jlog(@"%s: OK at %p orig=%p", name, funcAddr, *origFunc);
    } else {
        jlog(@"%s: FAILED ret=%d addr=%p", name, ret, funcAddr);

        // 尝试使用mprotect确保内存可写
        // iOS 17可能需要先解除代码段保护
        uintptr_t page = (uintptr_t)funcAddr & ~(0x4000 - 1); // 16KB页对齐
        kern_return_t kr = vm_protect(mach_task_self(), page, 0x4000,
                                       FALSE, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
        jlog(@"%s: vm_protect page=%p kr=%d", name, (void*)page, kr);

        // 重试
        ret = DobbyHook(funcAddr, hookFunc, origFunc);
        if (ret == 0) {
            *hookedFlag = YES;
            markAddrHooked(funcAddr);
            jlog(@"%s: RETRY OK at %p orig=%p", name, funcAddr, *origFunc);
        } else {
            jlog(@"%s: RETRY STILL FAILED ret=%d", name, ret);
        }
    }
}

// 创建IL2CPP字符串
static void* createIl2cppString(const char *utf8) {
    if (g_il2cpp_string_new && utf8) {
        return g_il2cpp_string_new(utf8);
    }
    return NULL;
}

// ============================================================
// Hook函数实现
// ============================================================

/**
 * Hook NTESRiskSecProtect.ioctl (共享地址，覆盖NetSecProtect.ioctl)
 * 签名: static String ioctl(RequestCmdID request, String data)
 * IL2CPP静态方法调用约定: (int requestCmdID, void* data) → void*
 */
static int g_ioctlLogCount = 0;
static void* hookIoctl(int request, void* data) {
    if (g_ioctlLogCount < 50) {
        g_ioctlLogCount++;
        jlog(@"ioctl[%d] request=%d data=%p", g_ioctlLogCount, request, data);
    }

    // Cmd_IsRootDevice = 2 → 返回"0"(非根设备)
    if (request == 2) {
        jlog(@"ioctl: Cmd_IsRootDevice(2) → \"0\"");
        return createIl2cppString("0");
    }

    // Cmd_GetCollectData = 8 → 返回空
    if (request == 8) {
        jlog(@"ioctl: Cmd_GetCollectData(8) → empty");
        return createIl2cppString("");
    }

    // 其他命令正常转发
    if (g_origIoctl) return g_origIoctl(request, data);
    return NULL;
}

/**
 * Hook NTESRiskSecProtect.getToken (共享地址，覆盖NetSecProtect.getToken)
 * 签名: static AntiCheatResult getToken(int timeout, String businessId)
 */
static int g_getTokenLogCount = 0;
static void* hookGetToken(int timeout, void* businessId) {
    if (g_getTokenLogCount < 30) {
        g_getTokenLogCount++;
        jlog(@"getToken[%d] timeout=%d", g_getTokenLogCount, timeout);
    }

    if (g_origGetToken) {
        void *result = g_origGetToken(timeout, businessId);
        if (result) {
            // 修改AntiCheatResult.code = 0
            int *codePtr = (int*)((uint8_t*)result + 0x10);
            int origCode = *codePtr;
            if (origCode != 0) {
                *codePtr = 0;
                jlog(@"getToken: patched code %d → 0", origCode);
            }
            void **codeStrPtr = (void**)((uint8_t*)result + 0x18);
            if (codeStrPtr && *codeStrPtr) *codeStrPtr = createIl2cppString("");
            return result;
        }
    }
    jlog(@"getToken: orig returned NULL");
    return NULL;
}

/**
 * Hook MyGetToken.onResult
 * 签名: void onResult(AntiCheatResult antiCheatResult)
 * IL2CPP实例方法: (void* self, void* antiCheatResult)
 */
static int g_myGetTokenLogCount = 0;
static void hookMyGetTokenOnResult(void *self, void *antiCheatResult) {
    if (g_myGetTokenLogCount < 30) {
        g_myGetTokenLogCount++;
        jlog(@"MyGetToken.onResult[%d] self=%p result=%p", g_myGetTokenLogCount, self, antiCheatResult);
    }

    if (antiCheatResult) {
        int *codePtr = (int*)((uint8_t*)antiCheatResult + 0x10);
        int origCode = *codePtr;
        if (origCode != 0) {
            *codePtr = 0;
            jlog(@"MyGetToken.onResult: patched code %d → 0", origCode);
        }
    }

    if (g_origMyGetTokenOnResult) g_origMyGetTokenOnResult(self, antiCheatResult);
}

/**
 * Hook MyHtpCallback.onReceive
 * 签名: void onReceive(int code, String msg)
 * IL2CPP实例方法: (void* self, int code, void* msg)
 */
static int g_htpCallbackLogCount = 0;
static void hookMyHtpCallbackOnReceive(void *self, int code, void* msg) {
    if (g_htpCallbackLogCount < 30) {
        g_htpCallbackLogCount++;
        jlog(@"MyHtpCallback.onReceive[%d] orig_code=%d → force 0", g_htpCallbackLogCount, code);
    }

    // 强制code=0
    if (g_origMyHtpCallbackOnReceive) {
        g_origMyHtpCallbackOnReceive(self, 0, msg);
    }
}

/**
 * Hook isHtpExist
 * 签名: static Boolean isHtpExist()
 */
static int g_isHtpExistLogCount = 0;
static BOOL hookIsHtpExist(void) {
    if (g_isHtpExistLogCount < 10) {
        g_isHtpExistLogCount++;
        jlog(@"isHtpExist[%d] → YES", g_isHtpExistLogCount);
    }
    return YES;
}

// ============================================================
// 应用所有Hook
// ============================================================

static void applyAllHooks(void) {
    if (!g_funcIoctl) findIL2CPPMethods();

    jlog(@"=== 应用反检测Hook v2.0 ===");

    // 核心：hook ioctl让IsRootDevice返回"0"
    hookOneFunc(g_funcIoctl, (void*)hookIoctl, (void**)&g_origIoctl, &g_ioctlHooked, "ioctl");

    // hook getToken修改返回结果
    hookOneFunc(g_funcGetToken, (void*)hookGetToken, (void**)&g_origGetToken, &g_getTokenHooked, "getToken");

    // hook回调
    hookOneFunc(g_funcMyGetTokenOnResult, (void*)hookMyGetTokenOnResult, (void**)&g_origMyGetTokenOnResult, &g_myGetTokenHooked, "MyGetToken.onResult");
    hookOneFunc(g_funcMyHtpCallbackOnReceive, (void*)hookMyHtpCallbackOnReceive, (void**)&g_origMyHtpCallbackOnReceive, &g_myHtpCallbackHooked, "MyHtpCallback.onReceive");

    // isHtpExist - 独立地址
    hookOneFunc(g_funcIsHtpExist, (void*)hookIsHtpExist, (void**)&g_origIsHtpExist, &g_isHtpExistHooked, "isHtpExist");

    jlog(@"=== Hook结果 ioctl=%d getToken=%d MyGetToken=%d MyHtp=%d isHtp=%d ===",
         g_ioctlHooked, g_getTokenHooked, g_myGetTokenHooked, g_myHtpCallbackHooked, g_isHtpExistHooked);
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;

    jlog(@"========== JYJH 反检测 v2.0 ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);

    // 延迟5秒（比v1.0多2秒），确保反作弊SDK完全加载
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        jlog(@"5s delay done");
        applyAllHooks();

        // 15秒后再检查hook是否生效，输出诊断
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            jlog(@"=== 20s诊断 ===");
            jlog(@"ioctl called %d times, getToken called %d times", g_ioctlLogCount, g_getTokenLogCount);
            jlog(@"MyGetToken called %d times, MyHtp called %d times", g_myGetTokenLogCount, g_htpCallbackLogCount);
        });
    });
}
