/**
 * 剑影江湖 反检测插件 v1.0
 * 屏蔽网易易盾NTESHTPSec反作弊系统检测
 *
 * 目标：iOS 17.0 未越狱 + 巨魔商店环境
 * 问题：游戏通过NTESHTPSec检测环境异常（根设备/注入等）
 *
 * Hook策略：
 * 1. ioctl(Cmd_IsRootDevice=2) → 返回"0"（非根设备）
 * 2. ioctl(Cmd_GetCollectData=8) → 返回空字符串（不收集数据）
 * 3. getToken → 返回AntiCheatResult(code=0, token="")
 * 4. MyGetToken.onResult → 确保code=0
 * 5. MyHtpCallback.onReceive → 确保code=0
 *
 * 关键地址（v1.10.1 dump.cs）：
 *   NTESRiskSecProtect.init       0x5d3003c  静态(String, InitCallback)
 *   NTESRiskSecProtect.ioctl      0x5d30a9c  静态(RequestCmdID, String)→String
 *   NTESRiskSecProtect.getToken   0x5d30410  静态(int, String)→AntiCheatResult
 *   NTESRiskSecProtect.setRoleInfo 0x5d30238 静态(String*7, int)→int
 *   NetSecProtect.init            0x5d33284  静态(String, HTPCallback, HTProtectConfig)
 *   NetSecProtect.ioctl           0x5d33420  静态(RequestCmdID, String)→String
 *   NetSecProtect.isHtpExist      0x5d33980  静态()→Boolean
 *   NetSecProtect.getToken        0x5d33988  静态(int, String)→AntiCheatResult
 *   MyGetToken.onResult           0x5d34b20  实例(AntiCheatResult)
 *   MyHtpCallback.onReceive       0x5d34c88  实例(int, String)
 *
 * 注意：所有NTESRiskSecProtect/NetSecProtect方法都是静态方法，
 *       IL2CPP静态方法无隐含this参数（不同于实例方法）。
 *       但IL2CPP的C#层静态方法编译后，有的仍可能有MethodInfo*参数，
 *       需要根据实际调用约定调整。此处采用运行时IL2CPP搜索方式，
 *       通过方法名匹配找到实际函数地址，避免硬编码偏移。
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
typedef uint32_t (*Il2CppMethodGetFlags)(void*);
typedef void* (*Il2CppMethodGetReturnType)(void*);
typedef const char* (*Il2CppTypeGetName)(void*);

// IL2CPP string创建
typedef void* (*Il2CppStringCreate)(const char*);
typedef void* (*Il2CppStringCreateUtf16)(const uint16_t*, int32_t);

// IL2CPP对象创建
typedef void* (*Il2CppClassNew)(void*);
typedef void* (*Il2CppObjectNew)(void*);

// ============================================================
// 找到的函数地址
// ============================================================

// NTESHTPSec.NTESRiskSecProtect
static void *g_funcInit = NULL;
static void *g_funcIoctl = NULL;
static void *g_funcGetToken = NULL;
static void *g_funcSetRoleInfo = NULL;
static void *g_funcGetTokenAsync = NULL;

// NetEase.NetSecProtect
static void *g_funcNetInit = NULL;
static void *g_funcNetIoctl = NULL;
static void *g_funcNetGetToken = NULL;
static void *g_funcIsHtpExist = NULL;
static void *g_funcNetGetTokenAsync = NULL;

// Main.Runtime.MyGetToken
static void *g_funcMyGetTokenOnResult = NULL;

// Main.Runtime.MyHtpCallback
static void *g_funcMyHtpCallbackOnReceive = NULL;

// Hook状态
static BOOL g_ioctlHooked = NO;
static BOOL g_getTokenHooked = NO;
static BOOL g_myGetTokenHooked = NO;
static BOOL g_myHtpCallbackHooked = NO;
static BOOL g_netIoctlHooked = NO;
static BOOL g_netGetTokenHooked = NO;
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

typedef void* (*FuncNetIoctl)(int requestCmdID, void* data);
static FuncNetIoctl g_origNetIoctl = NULL;

typedef void* (*FuncNetGetToken)(int timeout, void* businessId);
static FuncNetGetToken g_origNetGetToken = NULL;

typedef BOOL (*FuncIsHtpExist)(void);
static FuncIsHtpExist g_origIsHtpExist = NULL;

// IL2CPP运行时函数
static Il2CppStringCreate g_il2cpp_string_new = NULL;
static Il2CppClassNew g_il2cpp_class_new = NULL;

// ============================================================
// IL2CPP搜索
// ============================================================

// 搜索特定类+方法名
typedef struct {
    const char *className;  // NULL=匹配所有类
    const char *methodName;
    void **outAddr;
    const char *logName;
} MethodSearchEntry;

static void findIL2CPPMethods(void) {
    jlog(@"=== 反检测 v1.0 IL2CPP 搜索 ===");
    void *h = dlopen(NULL, RTLD_LAZY);
    if (!h) { jlog(@"dlopen FAIL"); return; }

    // 获取IL2CPP运行时API
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
    g_il2cpp_class_new = dlsym(h, "il2cpp_object_new");

    if (!domain_get || !method_name) { jlog(@"IL2CPP APIs not found"); return; }
    void *domain = domain_get();
    if (!domain) return;
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    if (!assemblies) return;
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);

    // 要搜索的方法列表
    // NTESHTPSec.NTESRiskSecProtect
    MethodSearchEntry searches[] = {
        {"NTESRiskSecProtect", "ioctl",       &g_funcIoctl,      "NTESRiskSecProtect.ioctl"},
        {"NTESRiskSecProtect", "getToken",    &g_funcGetToken,   "NTESRiskSecProtect.getToken"},
        {"NTESRiskSecProtect", "init",        &g_funcInit,       "NTESRiskSecProtect.init"},
        {"NTESRiskSecProtect", "setRoleInfo", &g_funcSetRoleInfo,"NTESRiskSecProtect.setRoleInfo"},
        {"NTESRiskSecProtect", "getTokenAsync",&g_funcGetTokenAsync,"NTESRiskSecProtect.getTokenAsync"},
        {"NetSecProtect",      "ioctl",       &g_funcNetIoctl,   "NetSecProtect.ioctl"},
        {"NetSecProtect",      "getToken",    &g_funcNetGetToken,"NetSecProtect.getToken"},
        {"NetSecProtect",      "init",        &g_funcNetInit,    "NetSecProtect.init"},
        {"NetSecProtect",      "isHtpExist",  &g_funcIsHtpExist, "NetSecProtect.isHtpExist"},
        {"NetSecProtect",      "getTokenAsync",&g_funcNetGetTokenAsync,"NetSecProtect.getTokenAsync"},
        {"MyGetToken",         "onResult",    &g_funcMyGetTokenOnResult, "MyGetToken.onResult"},
        {"MyHtpCallback",      "onReceive",   &g_funcMyHtpCallbackOnReceive,"MyHtpCallback.onReceive"},
        {NULL, NULL, NULL, NULL}
    };

    int found = 0;
    int totalMethods = 0;

    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;
            if (!cn) continue;

            // 跳过不相关的类（优化搜索速度）
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
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;
                uint32_t pc = param_count ? param_count(m) : 0;

                for (int i = 0; searches[i].methodName; i++) {
                    if (*searches[i].outAddr) continue; // 已找到
                    if (strcmp(n, searches[i].methodName) == 0) {
                        void *funcAddr = NULL;
                        memcpy(&funcAddr, m, sizeof(void*));
                        *(searches[i].outAddr) = funcAddr;
                        jlog(@"FOUND %s.%s params=%u addr=%p", cn, n, pc, funcAddr);
                        found++;
                    }
                }
            }
        }
    }

    jlog(@"Scanned %d methods in relevant classes, found %d targets", totalMethods, found);

    // 打印搜索结果
    jlog(@"=== 搜索结果 ===");
    jlog(@"NTESRiskSecProtect.ioctl = %p", g_funcIoctl);
    jlog(@"NTESRiskSecProtect.getToken = %p", g_funcGetToken);
    jlog(@"NTESRiskSecProtect.init = %p", g_funcInit);
    jlog(@"NTESRiskSecProtect.setRoleInfo = %p", g_funcSetRoleInfo);
    jlog(@"NTESRiskSecProtect.getTokenAsync = %p", g_funcGetTokenAsync);
    jlog(@"NetSecProtect.ioctl = %p", g_funcNetIoctl);
    jlog(@"NetSecProtect.getToken = %p", g_funcNetGetToken);
    jlog(@"NetSecProtect.init = %p", g_funcNetInit);
    jlog(@"NetSecProtect.isHtpExist = %p", g_funcIsHtpExist);
    jlog(@"NetSecProtect.getTokenAsync = %p", g_funcNetGetTokenAsync);
    jlog(@"MyGetToken.onResult = %p", g_funcMyGetTokenOnResult);
    jlog(@"MyHtpCallback.onReceive = %p", g_funcMyHtpCallbackOnReceive);
    jlog(@"il2cpp_string_new = %p", g_il2cpp_string_new);
}

// ============================================================
// Hook辅助
// ============================================================

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: not found, skip", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) {
        *hookedFlag = YES;
        jlog(@"%s: OK at %p orig=%p", name, funcAddr, *origFunc);
    } else {
        jlog(@"%s: FAILED ret=%d", name, ret);
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

// Cmd_IsRootDevice = 2
// Cmd_GetSignInfo = 0
// Cmd_GetHTPVersion = 7
// Cmd_GetCollectData = 8
// Cmd_SetConfigData = 16
// Cmd_SetResponseData = 17
// Cmd_GetDeviceId = 20

/**
 * Hook NTESHTPSec.NTESRiskSecProtect.ioctl
 * 签名: static String ioctl(RequestCmdID request, String data)
 * IL2CPP静态方法: (int requestCmdID, void* il2cppStringData) → void* il2cppStringResult
 *
 * 当request=2(Cmd_IsRootDevice)时返回"0"(非根设备)
 * 当request=8(Cmd_GetCollectData)时返回空字符串(不收集数据)
 */
static int g_ioctlLogCount = 0;
static void* hookIoctl(int request, void* data) {
    if (g_ioctlLogCount < 30) {
        g_ioctlLogCount++;
        jlog(@"ioctl[%d] request=%d data=%p", g_ioctlLogCount, request, data);
    }

    // Cmd_IsRootDevice = 2 → 返回"0"(非根设备)
    if (request == 2) {
        jlog(@"ioctl: Cmd_IsRootDevice(2) → return \"0\"");
        return createIl2cppString("0");
    }

    // Cmd_GetCollectData = 8 → 返回空字符串
    if (request == 8) {
        jlog(@"ioctl: Cmd_GetCollectData(8) → return empty");
        return createIl2cppString("");
    }

    // 其他命令正常转发
    if (g_origIoctl) return g_origIoctl(request, data);
    return NULL;
}

/**
 * Hook NetEase.NetSecProtect.ioctl
 * 签名同上
 */
static int g_netIoctlLogCount = 0;
static void* hookNetIoctl(int request, void* data) {
    if (g_netIoctlLogCount < 30) {
        g_netIoctlLogCount++;
        jlog(@"NetIoctl[%d] request=%d data=%p", g_netIoctlLogCount, request, data);
    }

    if (request == 2) {
        jlog(@"NetIoctl: Cmd_IsRootDevice(2) → return \"0\"");
        return createIl2cppString("0");
    }
    if (request == 8) {
        jlog(@"NetIoctl: Cmd_GetCollectData(8) → return empty");
        return createIl2cppString("");
    }

    if (g_origNetIoctl) return g_origNetIoctl(request, data);
    return NULL;
}

/**
 * Hook NTESHTPSec.NTESRiskSecProtect.getToken
 * 签名: static AntiCheatResult getToken(int timeout, String businessId)
 * IL2CPP: (int timeout, void* businessId) → void* (AntiCheatResult对象)
 *
 * 返回一个code=0(成功)的AntiCheatResult
 * AntiCheatResult字段布局(offset从0x10开始，因为IL2CPP对象头0x10):
 *   code(+0x10): int
 *   codeStr(+0x18): String*
 *   token(+0x20): String*
 *   businessId(+0x28): String*
 */
static int g_getTokenLogCount = 0;
static void* hookGetToken(int timeout, void* businessId) {
    if (g_getTokenLogCount < 20) {
        g_getTokenLogCount++;
        jlog(@"getToken[%d] timeout=%d → fake OK result", g_getTokenLogCount, timeout);
    }

    // 调用原函数获取结果，然后修改code=0
    if (g_origGetToken) {
        void *result = g_origGetToken(timeout, businessId);
        if (result) {
            // 修改AntiCheatResult.code = 0 (offset +0x10)
            int *codePtr = (int*)((uint8_t*)result + 0x10);
            int origCode = *codePtr;
            if (origCode != 0) {
                *codePtr = 0;
                jlog(@"getToken: patched code %d → 0", origCode);
            }
            // 清空codeStr (offset +0x18)
            void **codeStrPtr = (void**)((uint8_t*)result + 0x18);
            *codeStrPtr = createIl2cppString("");
            return result;
        }
    }

    // 如果原函数返回NULL，我们需要构造一个AntiCheatResult
    // 但构造IL2CPP对象需要klass指针，这里无法安全构造
    // 改为返回NULL让调用方处理
    jlog(@"getToken: orig returned NULL, cannot fake result");
    return NULL;
}

/**
 * Hook NetEase.NetSecProtect.getToken
 * 签名同上
 */
static int g_netGetTokenLogCount = 0;
static void* hookNetGetToken(int timeout, void* businessId) {
    if (g_netGetTokenLogCount < 20) {
        g_netGetTokenLogCount++;
        jlog(@"NetGetToken[%d] timeout=%d → patched result", g_netGetTokenLogCount, timeout);
    }

    if (g_origNetGetToken) {
        void *result = g_origNetGetToken(timeout, businessId);
        if (result) {
            int *codePtr = (int*)((uint8_t*)result + 0x10);
            int origCode = *codePtr;
            if (origCode != 0) {
                *codePtr = 0;
                jlog(@"NetGetToken: patched code %d → 0", origCode);
            }
            void **codeStrPtr = (void**)((uint8_t*)result + 0x18);
            *codeStrPtr = createIl2cppString("");
            return result;
        }
    }
    return NULL;
}

/**
 * Hook NetEase.NetSecProtect.isHtpExist
 * 签名: static Boolean isHtpExist()
 * IL2CPP: () → BOOL
 * 返回YES表示HTP存在（如果返回NO可能导致游戏认为SDK未初始化）
 */
static BOOL hookIsHtpExist(void) {
    jlog(@"isHtpExist → YES (HTP exists)");
    // 返回YES表示SDK存在（避免游戏认为未初始化而走不同路径）
    if (g_origIsHtpExist) {
        BOOL result = g_origIsHtpExist();
        jlog(@"isHtpExist orig=%d", result);
        return result;
    }
    return YES;
}

/**
 * Hook Main.Runtime.MyGetToken.onResult
 * 签名: void onResult(AntiCheatResult antiCheatResult)
 * IL2CPP实例方法: (void* self, void* antiCheatResult)
 *
 * 确保AntiCheatResult.code = 0
 */
static int g_myGetTokenLogCount = 0;
static void hookMyGetTokenOnResult(void *self, void *antiCheatResult) {
    if (g_myGetTokenLogCount < 20) {
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
        // 清空codeStr
        void **codeStrPtr = (void**)((uint8_t*)antiCheatResult + 0x18);
        if (codeStrPtr) *codeStrPtr = createIl2cppString("");
    }

    if (g_origMyGetTokenOnResult) g_origMyGetTokenOnResult(self, antiCheatResult);
}

/**
 * Hook Main.Runtime.MyHtpCallback.onReceive
 * 签名: void onReceive(int code, String msg)
 * IL2CPP实例方法: (void* self, int code, void* msg)
 *
 * 确保code = 0（初始化成功）
 */
static int g_htpCallbackLogCount = 0;
static void hookMyHtpCallbackOnReceive(void *self, int code, void *msg) {
    if (g_htpCallbackLogCount < 20) {
        g_htpCallbackLogCount++;
        jlog(@"MyHtpCallback.onReceive[%d] code=%d → force 0", g_htpCallbackLogCount, code);
    }

    // 强制code=0，表示初始化成功
    if (g_origMyHtpCallbackOnReceive) {
        g_origMyHtpCallbackOnReceive(self, 0, msg);
    }
}

// ============================================================
// 应用所有Hook
// ============================================================

static void applyAllHooks(void) {
    if (!g_funcIoctl && !g_funcGetToken) findIL2CPPMethods();

    jlog(@"=== 应用反检测Hook ===");

    // 核心：hook ioctl让IsRootDevice返回"0"
    hookOneFunc(g_funcIoctl, (void*)hookIoctl, (void**)&g_origIoctl, &g_ioctlHooked, "NTESRiskSecProtect.ioctl");

    // hook getToken修改返回结果
    hookOneFunc(g_funcGetToken, (void*)hookGetToken, (void**)&g_origGetToken, &g_getTokenHooked, "NTESRiskSecProtect.getToken");

    // hook MyGetToken.onResult确保回调结果code=0
    hookOneFunc(g_funcMyGetTokenOnResult, (void*)hookMyGetTokenOnResult, (void**)&g_origMyGetTokenOnResult, &g_myGetTokenHooked, "MyGetToken.onResult");

    // hook MyHtpCallback.onReceive确保初始化回调code=0
    hookOneFunc(g_funcMyHtpCallbackOnReceive, (void*)hookMyHtpCallbackOnReceive, (void**)&g_origMyHtpCallbackOnReceive, &g_myHtpCallbackHooked, "MyHtpCallback.onReceive");

    // NetEase.NetSecProtect的ioctl
    hookOneFunc(g_funcNetIoctl, (void*)hookNetIoctl, (void**)&g_origNetIoctl, &g_netIoctlHooked, "NetSecProtect.ioctl");

    // NetEase.NetSecProtect的getToken
    hookOneFunc(g_funcNetGetToken, (void*)hookNetGetToken, (void**)&g_origNetGetToken, &g_netGetTokenHooked, "NetSecProtect.getToken");

    // isHtpExist - 让它返回YES
    hookOneFunc(g_funcIsHtpExist, (void*)hookIsHtpExist, (void**)&g_origIsHtpExist, &g_isHtpExistHooked, "NetSecProtect.isHtpExist");

    jlog(@"=== Hook完成 ioctl=%d getToken=%d MyGetToken=%d MyHtp=%d NetIoctl=%d NetGetToken=%d isHtpExist=%d ===",
         g_ioctlHooked, g_getTokenHooked, g_myGetTokenHooked, g_myHtpCallbackHooked,
         g_netIoctlHooked, g_netGetTokenHooked, g_isHtpExistHooked);
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;

    jlog(@"========== JYJH 反检测 v1.0 (NTESHTPSec Bypass) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"目标: 屏蔽网易易盾反作弊环境检测");
    jlog(@"策略: ioctl(IsRootDevice)→0, getToken→patch code=0, callbacks→force code=0");

    // 延迟3秒执行，等待IL2CPP运行时初始化完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(3.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        jlog(@"3s delay done, applying hooks...");
        applyAllHooks();
    });
}
