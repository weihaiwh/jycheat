/**
 * 剑影江湖 反检测插件 v5.0
 * 极简方案：只做最安全的hook，不碰可能导致闪退的基础C函数
 *
 * v4.0问题：
 *   fishhook hook了stat/access/fopen/open等基础C函数→闪退
 *   原因：游戏自身也大量使用这些函数，hook它们导致游戏无法
 *   正常读取资源文件→直接闪退。日志重复4次也说明多次启动
 *   尝试都失败。
 *
 * v5.0策略改变：
 *   1. 完全移除fishhook（太危险，容易导致闪退）
 *   2. 只保留MethodInfo替换（v3.0已经验证不闪退）
 *   3. 重新分析为什么v3.0的MethodInfo替换不生效
 *
 *   v3.0关键发现：ioctl/getToken hook从未被调用
 *   → C#层ioctl/getToken确实没被游戏直接调用
 *   → 但反作弊检测结果是通过getTokenAsync回调返回的
 *   → 游戏通过MyGetToken.onResult和MyHtpCallback.onReceive
 *     接收结果，这两个v3.0确实hook了但也没被调用日志
 *   → 可能5秒延迟太晚了，反作弊在更早的时候就已经检测
 *
 * v5.0新策略：
 *   1. 缩短延迟到2秒（反作弊SDK在游戏启动初期就初始化）
 *   2. 也hook NTESRiskSecProtect.init → 让初始化回调也走我们的逻辑
 *   3. 也hook getTokenAsync → 拦截异步获取token
 *   4. 也hook NetSecProtect.isInitialized → 确保标记为已初始化
 *   5. 也hook HTProtectConfig的<ie>/<ic>/<isec>字段
 *
 * 关于用户提到的巨魔/JIT问题：
 *   - TrollStore在未越狱环境下无法开启JIT（这是iOS限制）
 *   - Unity IL2CPP游戏不需要JIT（AOT编译），JIT不影响反作弊
 *   - 反作弊检测的是：1)注入的dylib 2)环境异常 3)签名异常
 *   - 巨魔注入dylib本身就改变了进程环境，被native SDK检测
 *   - 在native层（C SDK），检测可能通过：
 *     a. _dyld_image_count() 检测额外dylib数量
 *     b. 直接syscall绕过hook检测
 *     c. 代码段完整性校验（PPL保护的__TEXT段）
 *   - 这些在未越狱环境确实无法绕过（没有tfp0/内核权限）
 *
 * 结论：如果native SDK通过syscall或直接内存校验检测，
 *   在未越狱+巨魔环境下确实可能无法完全绕过。
 *   v5.0尽力拦截所有IL2CPP层面的检测点。
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
typedef void* (*Il2CppStringNew)(const char*);
typedef void* (*Il2CppClassGetFieldFromName)(void*, const char*);
typedef void  (*Il2CppFieldStaticGetValue)(void*, void*);
typedef void  (*Il2CppFieldStaticSetValue)(void*, void*);

static Il2CppStringNew g_il2cpp_string_new = NULL;
static Il2CppFieldStaticSetValue g_il2cpp_field_static_set_value = NULL;
static Il2CppFieldStaticGetValue g_il2cpp_field_static_get_value = NULL;
static Il2CppClassGetFieldFromName g_il2cpp_class_get_field_from_name = NULL;

// ============================================================
// MethodInfo指针替换
// ============================================================

typedef struct { void *methodInfo; void *origMethodPtr; void *hookFunc; const char *name; } HookEntry;
#define MAX_HOOKS 32
static HookEntry g_hooks[MAX_HOOKS];
static int g_hookCount = 0;

static void* getMethodPtr(void *mi) { void *p; memcpy(&p, mi, sizeof(void*)); return p; }
static void setMethodPtr(void *mi, void *np) { memcpy(mi, &np, sizeof(void*)); }

static BOOL patchMethodInfo(void *mi, void *hf, const char *name) {
    if (!mi || g_hookCount >= MAX_HOOKS) return NO;
    void *op = getMethodPtr(mi);
    g_hooks[g_hookCount] = (HookEntry){mi, op, hf, name};
    g_hookCount++;
    setMethodPtr(mi, hf);
    jlog(@"MethodInfo: %s %p→%p", name, op, hf);
    return YES;
}

static void* findOrigMethodPtr(void *hf) {
    for (int i = 0; i < g_hookCount; i++) if (g_hooks[i].hookFunc == hf) return g_hooks[i].origMethodPtr;
    return NULL;
}

// ============================================================
// Hook函数实现
// ============================================================

// ioctl: Cmd_IsRootDevice(2)→"0", Cmd_GetCollectData(8)→""
static int g_ioctlLogCount = 0;
static void* hookIoctl(int request, void* data) {
    if (g_ioctlLogCount < 100) { g_ioctlLogCount++; jlog(@"ioctl[%d] req=%d", g_ioctlLogCount, request); }
    if (request == 2) { jlog(@"ioctl IsRoot → 0"); return g_il2cpp_string_new ? g_il2cpp_string_new("0") : NULL; }
    if (request == 8) { jlog(@"ioctl Collect → empty"); return g_il2cpp_string_new ? g_il2cpp_string_new("") : NULL; }
    void *op = findOrigMethodPtr((void*)hookIoctl);
    return op ? ((void*(*)(int,void*))op)(request, data) : NULL;
}

// getToken: patch code=0
static int g_getTokenLogCount = 0;
static void* hookGetToken(int timeout, void* businessId) {
    if (g_getTokenLogCount < 100) { g_getTokenLogCount++; jlog(@"getToken[%d] t=%d", g_getTokenLogCount, timeout); }
    void *op = findOrigMethodPtr((void*)hookGetToken);
    if (op) { void *r = ((void*(*)(int,void*))op)(timeout, businessId);
        if (r) { int *c = (int*)((uint8_t*)r + 0x10); if (*c != 0) { jlog(@"getToken code %d→0",*c); *c=0; }
                 void **cs = (void**)((uint8_t*)r + 0x18); if (cs && *cs) *cs = g_il2cpp_string_new ? g_il2cpp_string_new("") : NULL;
                 return r; }
    }
    return NULL;
}

// init: 让初始化回调也返回成功
static int g_initLogCount = 0;
static void hookInit(void* productId, void* callback) {
    if (g_initLogCount < 20) { g_initLogCount++; jlog(@"init[%d] productId=%p callback=%p", g_initLogCount, productId, callback); }
    // 先调原函数让SDK真正初始化
    void *op = findOrigMethodPtr((void*)hookInit);
    if (op) {
        ((void(*)(void*,void*))op)(productId, callback);
        jlog(@"init: orig called");
    }
}

// getTokenAsync: 拦截异步获取token
static int g_getTokenAsyncLogCount = 0;
static void hookGetTokenAsync(int timeout, void* businessId, void* callback) {
    if (g_getTokenAsyncLogCount < 50) { g_getTokenAsyncLogCount++; jlog(@"getTokenAsync[%d] t=%d", g_getTokenAsyncLogCount, timeout); }
    void *op = findOrigMethodPtr((void*)hookGetTokenAsync);
    if (op) ((void(*)(int,void*,void*))op)(timeout, businessId, callback);
}

// MyGetToken.onResult: patch code=0
static int g_myGetTokenLogCount = 0;
static void hookMyGetTokenOnResult(void *self, void *result) {
    if (g_myGetTokenLogCount < 100) { g_myGetTokenLogCount++; jlog(@"MyGetToken[%d] result=%p", g_myGetTokenLogCount, result); }
    if (result) { int *c = (int*)((uint8_t*)result + 0x10); if (*c != 0) { jlog(@"MyGetToken code %d→0",*c); *c=0; } }
    void *op = findOrigMethodPtr((void*)hookMyGetTokenOnResult);
    if (op) ((void(*)(void*,void*))op)(self, result);
}

// MyHtpCallback.onReceive: force code=0
static int g_htpCallbackLogCount = 0;
static void hookMyHtpCallbackOnReceive(void *self, int code, void* msg) {
    if (g_htpCallbackLogCount < 100) { g_htpCallbackLogCount++; jlog(@"MyHtp[%d] code=%d→0", g_htpCallbackLogCount, code); }
    void *op = findOrigMethodPtr((void*)hookMyHtpCallbackOnReceive);
    if (op) ((void(*)(void*,int,void*))op)(self, 0, msg);
}

// isHtpExist: YES
static int g_isHtpExistLogCount = 0;
static BOOL hookIsHtpExist(void) {
    if (g_isHtpExistLogCount < 20) { g_isHtpExistLogCount++; jlog(@"isHtpExist[%d]→YES", g_isHtpExistLogCount); }
    return YES;
}

// NetSecProtect.init: 让它也正常初始化
static int g_netInitLogCount = 0;
static void hookNetInit(void* productId, void* cb, void* config) {
    if (g_netInitLogCount < 20) { g_netInitLogCount++; jlog(@"NetInit[%d]", g_netInitLogCount); }
    void *op = findOrigMethodPtr((void*)hookNetInit);
    if (op) ((void(*)(void*,void*,void*))op)(productId, cb, config);
}

// NetSecProtect.ioctl: same as NTESRiskSecProtect.ioctl (shared address)
// NetSecProtect.getToken: same as NTESRiskSecProtect.getToken (shared address)
// Already covered by hookIoctl and hookGetToken

// NetSecProtect.isHtpExist already has hookIsHtpExist

// ============================================================
// 搜索并替换MethodInfo
// ============================================================

static void findAndPatchMethods(void) {
    jlog(@"=== v5.0 MethodInfo搜索 ===");
    void *h = dlopen(NULL, RTLD_LAZY);
    if (!h) { jlog(@"dlopen FAIL"); return; }

    Il2CppDomainGet domain_get = dlsym(h, "il2cpp_domain_get");
    Il2CppDomainGetAssemblies get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
    Il2CppAssemblyGetImage get_image = dlsym(h, "il2cpp_assembly_get_image");
    Il2CppImageGetClassCount class_count = dlsym(h, "il2cpp_image_get_class_count");
    Il2CppImageGetClass get_class = dlsym(h, "il2cpp_image_get_class");
    Il2CppClassGetMethods get_methods = dlsym(h, "il2cpp_class_get_methods");
    Il2CppMethodGetName method_name = dlsym(h, "il2cpp_method_get_name");
    Il2CppClassGetName class_name_func = dlsym(h, "il2cpp_class_get_name");

    g_il2cpp_string_new = dlsym(h, "il2cpp_string_new");
    g_il2cpp_field_static_set_value = dlsym(h, "il2cpp_field_static_set_value");
    g_il2cpp_field_static_get_value = dlsym(h, "il2cpp_field_static_get_value");
    g_il2cpp_class_get_field_from_name = dlsym(h, "il2cpp_class_get_field_from_name");

    if (!domain_get || !method_name) { jlog(@"IL2CPP APIs not found"); return; }
    void *domain = domain_get();
    if (!domain) return;
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    if (!assemblies) return;
    jlog(@"assemblies count=%zu", assemCount);

    // 扩展搜索列表 - 包含init和getTokenAsync
    typedef struct { const char *cn; const char *mn; void *hf; } S;
    S searches[] = {
        {"NTESRiskSecProtect","ioctl",(void*)hookIoctl},
        {"NTESRiskSecProtect","getToken",(void*)hookGetToken},
        {"NTESRiskSecProtect","init",(void*)hookInit},
        {"NTESRiskSecProtect","getTokenAsync",(void*)hookGetTokenAsync},
        {"MyGetToken","onResult",(void*)hookMyGetTokenOnResult},
        {"MyHtpCallback","onReceive",(void*)hookMyHtpCallbackOnReceive},
        {"NetSecProtect","isHtpExist",(void*)hookIsHtpExist},
        {"NetSecProtect","init",(void*)hookNetInit},
        // getTokenAsync for NetSecProtect too (但可能共享地址)
        {"NetSecProtect","getTokenAsync",(void*)hookGetTokenAsync},
        {NULL,NULL,NULL}
    };

    void *found[9] = {NULL};
    int foundCount = 0;

    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]); if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c); if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;
            if (!cn) continue;
            BOOL rel = NO;
            for (int i = 0; searches[i].cn; i++) if (strcmp(cn, searches[i].cn) == 0) { rel = YES; break; }
            if (!rel) continue;
            void *iter = NULL, *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                const char *n = method_name(m); if (!n) continue;
                for (int i = 0; searches[i].cn; i++) {
                    if (found[i]) continue;
                    if (strcmp(n, searches[i].mn) == 0) {
                        found[i] = m;
                        // 跳过共享地址的（同一个MethodInfo只能patch一次）
                        BOOL skip = NO;
                        for (int j = 0; j < i; j++) {
                            if (found[j] && getMethodPtr(m) == getMethodPtr(found[j])) {
                                jlog(@"%s.%s shares addr with earlier hook, skip", cn, n);
                                skip = YES;
                                // 但仍然标记为已找到（所以不重复搜索）
                                break;
                            }
                        }
                        if (!skip) {
                            jlog(@"FOUND %s.%s MI=%p ptr=%p", cn, n, m, getMethodPtr(m));
                            foundCount++;
                        }
                    }
                }
            }
        }
    }
    jlog(@"Found %d unique MethodInfos", foundCount);

    // 应用patch（只对不重复地址的）
    for (int i = 0; searches[i].cn; i++) {
        if (!found[i]) { jlog(@"%s.%s NOT FOUND", searches[i].cn, searches[i].mn); continue; }
        // 检查是否跟已patch的地址重复
        BOOL alreadyPatched = NO;
        void *thisPtr = getMethodPtr(found[i]);
        for (int j = 0; j < g_hookCount; j++) {
            if (g_hooks[j].origMethodPtr == thisPtr) { alreadyPatched = YES; break; }
        }
        if (alreadyPatched) { jlog(@"%s.%s addr already patched, skip", searches[i].cn, searches[i].mn); continue; }
        patchMethodInfo(found[i], searches[i].hf, searches[i].mn);
    }

    // 修改静态字段
    if (g_il2cpp_field_static_set_value && g_il2cpp_class_get_field_from_name) {
        for (size_t a = 0; a < assemCount; a++) {
            void *img = get_image(assemblies[a]); if (!img) continue;
            size_t cnt = class_count ? class_count(img) : 0;
            for (size_t c = 0; c < cnt; c++) {
                void *klass = get_class(img, c); if (!klass) continue;
                const char *cn = class_name_func ? class_name_func(klass) : NULL;
                if (!cn) continue;

                if (strcmp(cn, "NTESRiskSecProtect") == 0) {
                    void *field = g_il2cpp_class_get_field_from_name(klass, "isInitialized");
                    if (field) { BOOL v=YES; g_il2cpp_field_static_set_value(field, &v); jlog(@"NTESRiskSecProtect.isInitialized=YES"); }
                }
                if (strcmp(cn, "NetSecProtect") == 0) {
                    void *field = g_il2cpp_class_get_field_from_name(klass, "isInitialized");
                    if (field) { BOOL v=YES; g_il2cpp_field_static_set_value(field, &v); jlog(@"NetSecProtect.isInitialized=YES"); }
                }
                if (strcmp(cn, "HTProtectConfig") == 0) {
                    // <ie> = initEnvironment (bool)
                    void *fie = g_il2cpp_class_get_field_from_name(klass, "<ie>k__BackingField");
                    if (fie) { BOOL v=YES; g_il2cpp_field_static_set_value(fie, &v); jlog(@"HTProtectConfig.ie=YES"); }
                    // <ic> = initCrash (bool)
                    void *fic = g_il2cpp_class_get_field_from_name(klass, "<ic>k__BackingField");
                    if (fic) { BOOL v=YES; g_il2cpp_field_static_set_value(fic, &v); jlog(@"HTProtectConfig.ic=YES"); }
                    // <isec> = initSec (int)
                    void *fisec = g_il2cpp_class_get_field_from_name(klass, "<isec>k__BackingField");
                    if (fisec) { int v=0; g_il2cpp_field_static_set_value(fisec, &v); jlog(@"HTProtectConfig.isec=0"); }
                }
            }
        }
    }

    jlog(@"=== v5.0 patch完成, %d hooks ===", g_hookCount);
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;

    jlog(@"========== JYJH 反检测 v5.0 ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"策略: MethodInfo替换(不碰native层基础函数)");

    // 缩短延迟到2秒（反作弊SDK在游戏启动早期就初始化）
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(2.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        jlog(@"2s delay done");
        findAndPatchMethods();

        // 30秒后诊断
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(30.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            jlog(@"=== 32s诊断 ===");
            jlog(@"ioctl=%d getToken=%d init=%d getTokenAsync=%d",
                 g_ioctlLogCount, g_getTokenLogCount, g_initLogCount, g_getTokenAsyncLogCount);
            jlog(@"MyGetToken=%d MyHtp=%d isHtpExist=%d NetInit=%d",
                 g_myGetTokenLogCount, g_htpCallbackLogCount, g_isHtpExistLogCount, g_netInitLogCount);
            for (int i = 0; i < g_hookCount; i++) {
                void *cp = getMethodPtr(g_hooks[i].methodInfo);
                jlog(@"%s: current=%p hook=%p match=%d", g_hooks[i].name, cp, g_hooks[i].hookFunc, cp == g_hooks[i].hookFunc);
            }
        });
    });
}
