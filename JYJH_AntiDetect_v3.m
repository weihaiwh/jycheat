/**
 * 剑影江湖 反检测插件 v3.0
 * 屏蔽网易易盾NTESHTPSec反作弊系统检测
 *
 * v1.0/v2.0问题：
 *   DobbyHook在iOS 17上始终FAILED ret=-1
 *   vm_protect返回KERN_PROTECTION_FAILURE(kr=2)
 *   原因：iOS 17 PPL(Page Protection Layer)阻止修改代码页权限
 *   inline hook需要修改__TEXT段，PPL直接拒绝
 *
 * v3.0方案：MethodInfo指针替换（不修改代码段！）
 *   IL2CPP的MethodInfo结构体第一个字段是methodPointer
 *   直接修改MethodInfo->methodPointer指向我们的hook函数
 *   这修改的是堆内存中的数据结构，不碰代码段，PPL不管
 *
 *   MethodInfo.layout (ARM64):
 *     +0x00: void* methodPointer   ← 我们修改这里
 *     +0x08: void* invoker_method
 *     +0x10: ...
 *
 *   旧值保存到origMethodInfo.methodPointer，调用原函数时用
 *
 * 注意：这个方案跟v22(v29)游戏功能用的DobbyHook不同
 *       游戏功能插件在15.6越狱设备上运行，没有PPL问题
 *       这个反检测插件专门在17.0未越狱+巨魔环境下运行
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

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

// IL2CPP field操作
typedef void* (*Il2CppClassGetFieldFromName)(void*, const char*);
typedef size_t (*Il2CppFieldGetOffset)(void*);
typedef void  (*Il2CppFieldStaticGetValue)(void*, void*);
typedef void  (*Il2CppFieldStaticSetValue)(void*, void*);

// IL2CPP class查找
typedef void* (*Il2CppClassFromName)(void*, const char*, const char*);
typedef void* (*Il2CppImageGetClassCount2)(void*);
typedef void* (*Il2CppClassGetMethodFromName)(void*, const char*, int);

static Il2CppStringNew g_il2cpp_string_new = NULL;
static Il2CppFieldStaticGetValue g_il2cpp_field_static_get_value = NULL;
static Il2CppFieldStaticSetValue g_il2cpp_field_static_set_value = NULL;
static Il2CppClassGetFieldFromName g_il2cpp_class_get_field_from_name = NULL;
static Il2CppClassFromName g_il2cpp_class_from_name = NULL;
static Il2CppClassGetMethodFromName g_il2cpp_class_get_method_from_name = NULL;

// ============================================================
// MethodInfo指针替换
// ============================================================

// 保存原始methodPointer
typedef struct {
    void *methodInfo;      // MethodInfo指针
    void *origMethodPtr;   // 原始methodPointer
    void *hookFunc;        // hook函数
    const char *name;      // 名称(日志用)
} HookEntry;

#define MAX_HOOKS 16
static HookEntry g_hooks[MAX_HOOKS];
static int g_hookCount = 0;

// 读取MethodInfo的methodPointer（+0x00）
static void* getMethodPtr(void *methodInfo) {
    void *ptr = NULL;
    memcpy(&ptr, methodInfo, sizeof(void*));
    return ptr;
}

// 写入MethodInfo的methodPointer（+0x00）
static void setMethodPtr(void *methodInfo, void *newPtr) {
    memcpy(methodInfo, &newPtr, sizeof(void*));
}

// 注册并应用hook：替换MethodInfo->methodPointer
static BOOL patchMethodInfo(void *methodInfo, void *hookFunc, const char *name) {
    if (!methodInfo) { jlog(@"%s: methodInfo is NULL", name); return NO; }
    if (g_hookCount >= MAX_HOOKS) { jlog(@"%s: too many hooks", name); return NO; }

    void *origPtr = getMethodPtr(methodInfo);
    jlog(@"%s: MethodInfo=%p origPtr=%p → hook=%p", name, methodInfo, origPtr, hookFunc);

    // 保存原始信息
    g_hooks[g_hookCount].methodInfo = methodInfo;
    g_hooks[g_hookCount].origMethodPtr = origPtr;
    g_hooks[g_hookCount].hookFunc = hookFunc;
    g_hooks[g_hookCount].name = name;
    g_hookCount++;

    // 替换methodPointer
    setMethodPtr(methodInfo, hookFunc);
    jlog(@"%s: methodPointer replaced, verify=%p", name, getMethodPtr(methodInfo));

    return YES;
}

// 通过名称查找原始methodPointer
static void* findOrigMethodPtr(void *hookFunc) {
    for (int i = 0; i < g_hookCount; i++) {
        if (g_hooks[i].hookFunc == hookFunc) return g_hooks[i].origMethodPtr;
    }
    return NULL;
}

// ============================================================
// Hook函数实现
// ============================================================

/**
 * Hook NTESRiskSecProtect.ioctl / NetSecProtect.ioctl (共享地址)
 * 签名: static String ioctl(RequestCmdID request, String data)
 * IL2CPP静态方法: (int requestCmdID, void* data) → void*
 */
static int g_ioctlLogCount = 0;
static void* hookIoctl(int request, void* data) {
    if (g_ioctlLogCount < 50) {
        g_ioctlLogCount++;
        jlog(@"ioctl[%d] request=%d", g_ioctlLogCount, request);
    }

    // Cmd_IsRootDevice = 2 → 返回"0"(非根设备)
    if (request == 2) {
        jlog(@"ioctl: Cmd_IsRootDevice(2) → \"0\"");
        return g_il2cpp_string_new ? g_il2cpp_string_new("0") : NULL;
    }

    // Cmd_GetCollectData = 8 → 返回空
    if (request == 8) {
        jlog(@"ioctl: Cmd_GetCollectData(8) → empty");
        return g_il2cpp_string_new ? g_il2cpp_string_new("") : NULL;
    }

    // 其他命令调原函数
    void *origPtr = findOrigMethodPtr((void*)hookIoctl);
    if (origPtr) {
        void* (*orig)(int, void*) = (void* (*)(int, void*))origPtr;
        return orig(request, data);
    }
    return NULL;
}

/**
 * Hook NTESRiskSecProtect.getToken / NetSecProtect.getToken (共享地址)
 * 签名: static AntiCheatResult getToken(int timeout, String businessId)
 * IL2CPP: (int timeout, void* businessId) → void*
 */
static int g_getTokenLogCount = 0;
static void* hookGetToken(int timeout, void* businessId) {
    if (g_getTokenLogCount < 30) {
        g_getTokenLogCount++;
        jlog(@"getToken[%d] timeout=%d", g_getTokenLogCount, timeout);
    }

    void *origPtr = findOrigMethodPtr((void*)hookGetToken);
    if (origPtr) {
        void* (*orig)(int, void*) = (void* (*)(int, void*))origPtr;
        void *result = orig(timeout, businessId);
        if (result) {
            // 修改AntiCheatResult.code = 0
            int *codePtr = (int*)((uint8_t*)result + 0x10);
            int origCode = *codePtr;
            if (origCode != 0) {
                *codePtr = 0;
                jlog(@"getToken: patched code %d → 0", origCode);
            }
            void **codeStrPtr = (void**)((uint8_t*)result + 0x18);
            if (codeStrPtr && *codeStrPtr) {
                *codeStrPtr = g_il2cpp_string_new ? g_il2cpp_string_new("") : NULL;
            }
            return result;
        }
    }
    jlog(@"getToken: no orig func or NULL result");
    return NULL;
}

/**
 * Hook MyGetToken.onResult
 * 签名(实例方法): (void* self, void* antiCheatResult) → void
 */
static int g_myGetTokenLogCount = 0;
static void hookMyGetTokenOnResult(void *self, void *antiCheatResult) {
    if (g_myGetTokenLogCount < 30) {
        g_myGetTokenLogCount++;
        jlog(@"MyGetToken.onResult[%d]", g_myGetTokenLogCount);
    }

    if (antiCheatResult) {
        int *codePtr = (int*)((uint8_t*)antiCheatResult + 0x10);
        int origCode = *codePtr;
        if (origCode != 0) {
            *codePtr = 0;
            jlog(@"MyGetToken: patched code %d → 0", origCode);
        }
    }

    void *origPtr = findOrigMethodPtr((void*)hookMyGetTokenOnResult);
    if (origPtr) {
        void (*orig)(void*, void*) = (void (*)(void*, void*))origPtr;
        orig(self, antiCheatResult);
    }
}

/**
 * Hook MyHtpCallback.onReceive
 * 签名(实例方法): (void* self, int code, void* msg) → void
 */
static int g_htpCallbackLogCount = 0;
static void hookMyHtpCallbackOnReceive(void *self, int code, void* msg) {
    if (g_htpCallbackLogCount < 30) {
        g_htpCallbackLogCount++;
        jlog(@"MyHtpCallback.onReceive[%d] orig_code=%d → force 0", g_htpCallbackLogCount, code);
    }

    void *origPtr = findOrigMethodPtr((void*)hookMyHtpCallbackOnReceive);
    if (origPtr) {
        void (*orig)(void*, int, void*) = (void (*)(void*, int, void*))origPtr;
        orig(self, 0, msg); // 强制code=0
    }
}

/**
 * Hook isHtpExist
 * 签名(静态方法): () → BOOL
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
// IL2CPP搜索MethodInfo
// ============================================================

// 要搜索的方法列表
typedef struct {
    const char *className;
    const char *methodName;
    void *hookFunc;
    const char *logName;
} SearchEntry;

// 搜索结果：保存MethodInfo指针（不是methodPointer，是MethodInfo结构体本身）
static void *g_minfoIoctl = NULL;
static void *g_minfoGetToken = NULL;
static void *g_minfoMyGetTokenOnResult = NULL;
static void *g_minfoMyHtpCallbackOnReceive = NULL;
static void *g_minfoIsHtpExist = NULL;

static void findAndPatchMethods(void) {
    jlog(@"=== 反检测 v3.0 MethodInfo搜索 ===");

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
    g_il2cpp_field_static_get_value = dlsym(h, "il2cpp_field_static_get_value");
    g_il2cpp_field_static_set_value = dlsym(h, "il2cpp_field_static_set_value");
    g_il2cpp_class_get_field_from_name = dlsym(h, "il2cpp_class_get_field_from_name");
    g_il2cpp_class_from_name = dlsym(h, "il2cpp_class_from_name");
    g_il2cpp_class_get_method_from_name = dlsym(h, "il2cpp_class_get_method_from_name");

    jlog(@"il2cpp_string_new=%p", g_il2cpp_string_new);
    jlog(@"il2cpp_field_static_set_value=%p", g_il2cpp_field_static_set_value);
    jlog(@"il2cpp_class_get_field_from_name=%p", g_il2cpp_class_get_field_from_name);

    if (!domain_get || !method_name) { jlog(@"IL2CPP APIs not found"); return; }
    void *domain = domain_get();
    if (!domain) return;
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    if (!assemblies) return;
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);

    // 搜索配置
    SearchEntry searches[] = {
        {"NTESRiskSecProtect", "ioctl",     (void*)hookIoctl,                   "ioctl"},
        {"NTESRiskSecProtect", "getToken",  (void*)hookGetToken,                "getToken"},
        {"MyGetToken",         "onResult",  (void*)hookMyGetTokenOnResult,      "MyGetToken.onResult"},
        {"MyHtpCallback",      "onReceive", (void*)hookMyHtpCallbackOnReceive,  "MyHtpCallback.onReceive"},
        {"NetSecProtect",      "isHtpExist",(void*)hookIsHtpExist,              "isHtpExist"},
        {NULL, NULL, NULL, NULL}
    };

    void **minfoPtrs[] = {
        &g_minfoIoctl,
        &g_minfoGetToken,
        &g_minfoMyGetTokenOnResult,
        &g_minfoMyHtpCallbackOnReceive,
        &g_minfoIsHtpExist,
        NULL
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

                for (int i = 0; searches[i].methodName; i++) {
                    if (*minfoPtrs[i]) continue; // 已找到
                    if (strcmp(n, searches[i].methodName) == 0) {
                        // m就是MethodInfo指针！不需要memcpy
                        // m本身指向MethodInfo结构体，+0x00就是methodPointer
                        *minfoPtrs[i] = m;
                        void *funcAddr = getMethodPtr(m);
                        jlog(@"FOUND %s.%s MethodInfo=%p methodPtr=%p", cn, n, m, funcAddr);
                        found++;
                    }
                }
            }
        }
    }

    jlog(@"Found %d MethodInfos", found);

    // ============================================================
    // 应用MethodInfo指针替换
    // ============================================================

    jlog(@"=== 应用MethodInfo指针替换 ===");

    // 核心hook
    if (g_minfoIoctl) {
        patchMethodInfo(g_minfoIoctl, (void*)hookIoctl, "ioctl");
    } else { jlog(@"ioctl MethodInfo NOT FOUND"); }

    if (g_minfoGetToken) {
        patchMethodInfo(g_minfoGetToken, (void*)hookGetToken, "getToken");
    } else { jlog(@"getToken MethodInfo NOT FOUND"); }

    if (g_minfoMyGetTokenOnResult) {
        patchMethodInfo(g_minfoMyGetTokenOnResult, (void*)hookMyGetTokenOnResult, "MyGetToken.onResult");
    } else { jlog(@"MyGetToken.onResult MethodInfo NOT FOUND"); }

    if (g_minfoMyHtpCallbackOnReceive) {
        patchMethodInfo(g_minfoMyHtpCallbackOnReceive, (void*)hookMyHtpCallbackOnReceive, "MyHtpCallback.onReceive");
    } else { jlog(@"MyHtpCallback.onReceive MethodInfo NOT FOUND"); }

    if (g_minfoIsHtpExist) {
        patchMethodInfo(g_minfoIsHtpExist, (void*)hookIsHtpExist, "isHtpExist");
    } else { jlog(@"isHtpExist MethodInfo NOT FOUND"); }

    jlog(@"=== MethodInfo替换完成，共%d个 ===", g_hookCount);

    // ============================================================
    // 额外：修改isInitialized静态字段
    // ============================================================
    if (g_il2cpp_field_static_set_value && g_il2cpp_class_get_field_from_name) {
        // 找到NTESRiskSecProtect类
        // isInitialized是静态bool字段，确保为true
        for (size_t a = 0; a < assemCount; a++) {
            void *img = get_image(assemblies[a]);
            if (!img) continue;
            size_t cnt = class_count ? class_count(img) : 0;
            for (size_t c = 0; c < cnt; c++) {
                void *klass = get_class(img, c);
                if (!klass) continue;
                const char *cn = class_name_func ? class_name_func(klass) : NULL;
                if (!cn) continue;
                if (strcmp(cn, "NTESRiskSecProtect") == 0) {
                    void *field = g_il2cpp_class_get_field_from_name(klass, "isInitialized");
                    if (field) {
                        jlog(@"Found isInitialized field=%p", field);
                        BOOL val = YES;
                        g_il2cpp_field_static_set_value(field, &val);
                        // 验证
                        BOOL readVal = NO;
                        if (g_il2cpp_field_static_get_value) {
                            g_il2cpp_field_static_get_value(field, &readVal);
                        }
                        jlog(@"isInitialized set to YES, read back=%d", readVal);
                    } else {
                        jlog(@"isInitialized field not found");
                    }
                    goto done_init_field;
                }
            }
        }
        done_init_field:;
    }
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;

    jlog(@"========== JYJH 反检测 v3.0 (MethodInfo替换) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"方案: MethodInfo->methodPointer替换(不修改代码段，绕过PPL)");

    // 延迟5秒
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        jlog(@"5s delay done");
        findAndPatchMethods();

        // 15秒后诊断
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            jlog(@"=== 20s诊断 ===");
            jlog(@"ioctl calls=%d, getToken calls=%d", g_ioctlLogCount, g_getTokenLogCount);
            jlog(@"MyGetToken calls=%d, MyHtp calls=%d, isHtpExist calls=%d",
                 g_myGetTokenLogCount, g_htpCallbackLogCount, g_isHtpExistLogCount);
            // 验证MethodInfo是否被改回
            for (int i = 0; i < g_hookCount; i++) {
                void *currentPtr = getMethodPtr(g_hooks[i].methodInfo);
                jlog(@"%s: currentPtr=%p hookFunc=%p match=%d",
                     g_hooks[i].name, currentPtr, g_hooks[i].hookFunc,
                     currentPtr == g_hooks[i].hookFunc);
            }
        });
    });
}
