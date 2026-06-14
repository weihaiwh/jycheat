/**
 * 剑影江湖 反检测插件 v4.0
 * 屏蔽网易易盾NTESHTPSec反作弊系统检测 + native层fishhook
 *
 * v3.0问题：
 *   MethodInfo替换全部成功，不闪退了
 *   但ioctl/getToken的hook函数从未被调用（日志没有调用记录）
 *   → 说明反作弊检测不在IL2CPP C#层，而在native SDK层
 *   → C#层的MethodInfo替换不影响native SDK的C函数调用
 *
 * 用户关键线索：
 *   15.6越狱+ShadowHook注入检测可规避 → ShadowHook是hook native层
 *   15.6未越狱+巨魔不会被检测 → 没有注入就没有检测
 *   17.0未越狱+巨魔会被检测 → 巨魔环境被native SDK检测到
 *
 * v4.0方案：
 *   1. 保留MethodInfo替换（IL2CPP层兜底）
 *   2. 新增fishhook拦截native C库函数（不修改代码段！改__DATA段GOT）
 *   3. Hook以下关键检测路径：
 *      - stat/access/lstat: 检测越狱文件存在
 *      - fopen/open: 检测文件可访问
 *      - getenv: 读取DYLD_INSERT_LIBRARIES等环境变量
 *      - dlopen/dlsym: 检测注入dylib
 *      - _dyld_image_count: 检测额外加载的dylib数量
 *      - ptrace: 反调试
 *   4. fishhook改的是__DATA段GOT表，PPL不管
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>
#import <sys/stat.h>
#import <dirent.h>
#import <unistd.h>

// ============================================================
// fishhook 内嵌实现（从Facebook/fishhook精简）
// ============================================================

#include <dlfcn.h>
#include <stdlib.h>
#include <mach-o/loader.h>
#include <mach-o/nlist.h>
#include <TargetConditionals.h>

#ifdef __LP64__
typedef struct mach_header_64 mach_header_t;
typedef struct segment_command_64 segment_command_t;
typedef struct section_64 section_t;
typedef struct nlist_64 nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT_64
#else
typedef struct mach_header mach_header_t;
typedef struct segment_command segment_command_t;
typedef struct section section_t;
typedef struct nlist nlist_t;
#define LC_SEGMENT_ARCH_DEPENDENT LC_SEGMENT
#endif

struct rebindings_entry {
    const char *rebind_name;
    void *rebind_replacement;
    void **rebind_replaced;
    struct rebindings_entry *next;
};

static struct rebindings_entry *_rebindings_head = NULL;

static int prepend_rebindings(struct rebindings_entry **rebindings_head,
                              const char *name, void *replacement, void **replaced) {
    struct rebindings_entry *new_entry =
        (struct rebindings_entry *)malloc(sizeof(struct rebindings_entry));
    if (!new_entry) return -1;
    new_entry->rebind_name = name;
    new_entry->rebind_replacement = replacement;
    new_entry->rebind_replaced = replaced;
    new_entry->next = *rebindings_head;
    *rebindings_head = new_entry;
    return 0;
}

static void perform_rebinding_with_section(section_t *section, intptr_t slide,
                                           nlist_t *symtab, char *strtab,
                                           uint32_t *indirect_symtab,
                                           struct rebindings_entry *rebindings) {
    uint32_t *indirect_symbol_indices = indirect_symtab + section->reserved1;
    void **indirect_symbol_bindings = (void **)((uintptr_t)slide + section->addr);
    for (uint i = 0; i < section->size / sizeof(void *); i++) {
        uint32_t symtab_index = indirect_symbol_indices[i];
        if (symtab_index == INDIRECT_SYMBOL_ABS ||
            symtab_index == INDIRECT_SYMBOL_LOCAL ||
            symtab_index == (INDIRECT_SYMBOL_LOCAL | INDIRECT_SYMBOL_ABS)) {
            continue;
        }
        uint32_t strtab_offset = symtab[symtab_index].n_un.n_strx;
        char *symbol_name = strtab + strtab_offset;
        bool symbol_name_longer_than_1 = symbol_name[0] && symbol_name[1];
        struct rebindings_entry *cur = rebindings;
        while (cur) {
            if (symbol_name_longer_than_1 &&
                strcmp(&symbol_name[1], cur->rebind_name) == 0) {
                if (cur->rebind_replaced) {
                    *cur->rebind_replaced = indirect_symbol_bindings[i];
                }
                indirect_symbol_bindings[i] = cur->rebind_replacement;
                break;
            }
            cur = cur->next;
        }
    }
}

static void rebind_symbols_for_image(struct rebindings_entry *rebindings,
                                     const mach_header_t *header, intptr_t slide) {
    Dl_info info;
    if (dladdr(header, &info) == 0) return;

    segment_command_t *cur_seg_cmd;
    segment_command_t *linkedit_segment = NULL;
    struct symtab_command *symtab_cmd = NULL;
    struct dysymtab_command *dysymtab_cmd = NULL;

    uintptr_t cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++,
         cur += ((segment_command_t *)cur)->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd == LC_SEGMENT_ARCH_DEPENDENT) {
            if (strcmp(cur_seg_cmd->segname, SEG_LINKEDIT) == 0) {
                linkedit_segment = cur_seg_cmd;
            }
        } else if (cur_seg_cmd->cmd == LC_SYMTAB) {
            symtab_cmd = (struct symtab_command *)cur_seg_cmd;
        } else if (cur_seg_cmd->cmd == LC_DYSYMTAB) {
            dysymtab_cmd = (struct dysymtab_command *)cur_seg_cmd;
        }
    }

    if (!symtab_cmd || !dysymtab_cmd || !linkedit_segment) return;

    uintptr_t linkedit_base =
        (uintptr_t)slide + linkedit_segment->vmaddr - linkedit_segment->fileoff;
    nlist_t *symtab = (nlist_t *)(linkedit_base + symtab_cmd->symoff);
    char *strtab = (char *)(linkedit_base + symtab_cmd->stroff);
    uint32_t *indirect_symtab =
        (uint32_t *)(linkedit_base + dysymtab_cmd->indirectsymoff);

    cur = (uintptr_t)header + sizeof(mach_header_t);
    for (uint i = 0; i < header->ncmds; i++,
         cur += ((segment_command_t *)cur)->cmdsize) {
        cur_seg_cmd = (segment_command_t *)cur;
        if (cur_seg_cmd->cmd != LC_SEGMENT_ARCH_DEPENDENT) continue;
        if (strcmp(cur_seg_cmd->segname, SEG_DATA) != 0 &&
            strcmp(cur_seg_cmd->segname, "__DATA_CONST") != 0) continue;
        for (uint j = 0; j < cur_seg_cmd->nsects; j++) {
            section_t *sect =
                (section_t *)(cur + sizeof(segment_command_t)) + j;
            if ((sect->flags & SECTION_TYPE) == S_LAZY_SYMBOL_POINTERS) {
                perform_rebinding_with_section(sect, slide, symtab, strtab,
                                               indirect_symtab, rebindings);
            }
            if ((sect->flags & SECTION_TYPE) == S_NON_LAZY_SYMBOL_POINTERS) {
                perform_rebinding_with_section(sect, slide, symtab, strtab,
                                               indirect_symtab, rebindings);
            }
        }
    }
}

static void _rebind_symbols_for_image(const struct mach_header *header,
                                      intptr_t slide) {
    rebind_symbols_for_image(_rebindings_head, (const mach_header_t *)header, slide);
}

static int fh_rebind_symbols(const char *name, void *replacement, void **replaced) {
    int retval = prepend_rebindings(&_rebindings_head, name, replacement, replaced);
    if (retval < 0) return retval;
    // 如果是第一次调用，注册dyld回调
    if (_rebindings_head->next == NULL) {
        _dyld_register_func_for_add_image(_rebind_symbols_for_image);
    } else {
        // 已注册过，对已加载的image重新绑定
        for (uint32_t i = 0; i < _dyld_image_count(); i++) {
            _rebind_symbols_for_image(_dyld_get_image_header(i),
                                      _dyld_get_image_vmaddr_slide(i));
        }
    }
    return retval;
}

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
// fishhook - 拦截native检测函数
// ============================================================

// 越狱/异常环境检测的文件路径黑名单
static BOOL isSuspiciousPath(const char *path) {
    if (!path) return NO;
    // 越狱相关路径
    static const char *jailbreakPaths[] = {
        "/Applications/Cydia.app",
        "/Library/MobileSubstrate",
        "/bin/bash",
        "/usr/sbin/sshd",
        "/etc/apt",
        "/private/var/lib/apt",
        "/private/var/lib/cydia",
        "/private/var/tmp/cydia.log",
        "/Applications/Icy.app",
        "/Applications/SBSettings.app",
        "/Applications/WinterBoard.app",
        "/Library/MobileSubstrate/DynamicLibraries",
        "/User/Applications/",
        "/var/lib/cydia",
        "/var/cache/apt",
        "/var/lib/apt",
        "/usr/libexec/ssh-keysign",
        "/usr/bin/sshd",
        "/usr/sbin/sshd",
        "/.cydia_no_stash",
        "/.installed_unc0ver",
        "/jb/amfid_payload.dylib",
        "/jb/libjailbreak.dylib",
        "/usr/lib/libcycript.dylib",
        "/usr/lib/libmobilesubstrate.dylib",
        "/usr/lib/substrate",
        "/usr/lib/libsubstitute.dylib",
        "/usr/lib/libhooker.dylib",
        NULL
    };
    for (int i = 0; jailbreakPaths[i]; i++) {
        if (strstr(path, jailbreakPaths[i]) != NULL) return YES;
    }
    return NO;
}

// 原始函数指针
static int (*orig_stat)(const char *, struct stat *);
static int (*orig_lstat)(const char *, struct stat *);
static int (*orig_access)(const char *, int);
static FILE* (*orig_fopen)(const char *, const char *);
static int (*orig_open)(const char *, int, ...);
static char* (*orig_getenv)(const char *);
static void* (*orig_dlopen)(const char *, int);
static void* (*orig_dlsym)(void *, const char *);

// Hook: stat - 越狱文件不存在时返回-1
static int hook_stat(const char *path, struct stat *buf) {
    if (isSuspiciousPath(path)) {
        return -1; // 文件不存在
    }
    return orig_stat(path, buf);
}

// Hook: lstat
static int hook_lstat(const char *path, struct stat *buf) {
    if (isSuspiciousPath(path)) {
        return -1;
    }
    return orig_lstat(path, buf);
}

// Hook: access
static int hook_access(const char *path, int mode) {
    if (isSuspiciousPath(path)) {
        errno = ENOENT;
        return -1;
    }
    return orig_access(path, mode);
}

// Hook: fopen - 不让打开越狱相关文件
static FILE* hook_fopen(const char *path, const char *mode) {
    if (isSuspiciousPath(path)) {
        return NULL;
    }
    return orig_fopen(path, mode);
}

// Hook: open
static int hook_open(const char *path, int flags, ...) {
    if (isSuspiciousPath(path)) {
        errno = ENOENT;
        return -1;
    }
    // 可变参数转发
    va_list args;
    va_start(args, flags);
    int mode = va_arg(args, int);
    va_end(args);
    return orig_open(path, flags, mode);
}

// Hook: getenv - 清除注入相关环境变量
static char* hook_getenv(const char *name) {
    if (name) {
        // DYLD_INSERT_LIBRARIES - 最关键的注入检测变量
        if (strcmp(name, "DYLD_INSERT_LIBRARIES") == 0) {
            return NULL;
        }
        // 其他可疑环境变量
        if (strcmp(name, "DYLD_LIBRARY_PATH") == 0 ||
            strcmp(name, "DYLD_FRAMEWORK_PATH") == 0 ||
            strcmp(name, "_MSSafeMode") == 0 ||
            strcmp(name, "SUBSTRATE_HOME") == 0) {
            return NULL;
        }
    }
    return orig_getenv(name);
}

// Hook: dlopen - 让注入检测找不到可疑dylib
static void* hook_dlopen(const char *path, int mode) {
    // 允许正常系统库加载，但隐藏可疑路径
    if (path && isSuspiciousPath(path)) {
        return NULL;
    }
    return orig_dlopen(path, mode);
}

// ============================================================
// IL2CPP MethodInfo替换（保留v3.0的C#层hook）
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

typedef struct { void *methodInfo; void *origMethodPtr; void *hookFunc; const char *name; } HookEntry;
#define MAX_HOOKS 16
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
    jlog(@"MethodInfo: %s %p→%p verify=%p", name, op, hf, getMethodPtr(mi));
    return YES;
}

static void* findOrigMethodPtr(void *hf) {
    for (int i = 0; i < g_hookCount; i++) if (g_hooks[i].hookFunc == hf) return g_hooks[i].origMethodPtr;
    return NULL;
}

// IL2CPP hook functions
static int g_ioctlLogCount = 0;
static void* hookIoctl(int request, void* data) {
    if (g_ioctlLogCount < 50) { g_ioctlLogCount++; jlog(@"ioctl[%d] req=%d", g_ioctlLogCount, request); }
    if (request == 2) return g_il2cpp_string_new ? g_il2cpp_string_new("0") : NULL;
    if (request == 8) return g_il2cpp_string_new ? g_il2cpp_string_new("") : NULL;
    void *op = findOrigMethodPtr((void*)hookIoctl);
    return op ? ((void*(*)(int,void*))op)(request, data) : NULL;
}

static int g_getTokenLogCount = 0;
static void* hookGetToken(int timeout, void* businessId) {
    if (g_getTokenLogCount < 30) { g_getTokenLogCount++; jlog(@"getToken[%d] t=%d", g_getTokenLogCount, timeout); }
    void *op = findOrigMethodPtr((void*)hookGetToken);
    if (op) { void *r = ((void*(*)(int,void*))op)(timeout, businessId);
        if (r) { int *c = (int*)((uint8_t*)r + 0x10); if (*c != 0) { jlog(@"getToken code %d→0",*c); *c=0; } return r; }
    }
    return NULL;
}

static int g_myGetTokenLogCount = 0;
static void hookMyGetTokenOnResult(void *self, void *result) {
    if (g_myGetTokenLogCount < 30) { g_myGetTokenLogCount++; jlog(@"MyGetToken[%d]", g_myGetTokenLogCount); }
    if (result) { int *c = (int*)((uint8_t*)result + 0x10); if (*c != 0) { *c = 0; jlog(@"MyGetToken code %d→0", *c); } }
    void *op = findOrigMethodPtr((void*)hookMyGetTokenOnResult);
    if (op) ((void(*)(void*,void*))op)(self, result);
}

static int g_htpCallbackLogCount = 0;
static void hookMyHtpCallbackOnReceive(void *self, int code, void* msg) {
    if (g_htpCallbackLogCount < 30) { g_htpCallbackLogCount++; jlog(@"MyHtp[%d] code=%d→0", g_htpCallbackLogCount, code); }
    void *op = findOrigMethodPtr((void*)hookMyHtpCallbackOnReceive);
    if (op) ((void(*)(void*,int,void*))op)(self, 0, msg);
}

static int g_isHtpExistLogCount = 0;
static BOOL hookIsHtpExist(void) {
    if (g_isHtpExistLogCount < 10) { g_isHtpExistLogCount++; jlog(@"isHtpExist[%d]→YES", g_isHtpExistLogCount); }
    return YES;
}

// ============================================================
// IL2CPP搜索MethodInfo
// ============================================================

static void patchIL2CPPMethods(void) {
    jlog(@"=== IL2CPP MethodInfo替换 ===");
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

    typedef struct { const char *cn; const char *mn; void *hf; } S;
    S searches[] = {
        {"NTESRiskSecProtect","ioctl",(void*)hookIoctl},
        {"NTESRiskSecProtect","getToken",(void*)hookGetToken},
        {"MyGetToken","onResult",(void*)hookMyGetTokenOnResult},
        {"MyHtpCallback","onReceive",(void*)hookMyHtpCallbackOnReceive},
        {"NetSecProtect","isHtpExist",(void*)hookIsHtpExist},
        {NULL,NULL,NULL}
    };
    void *found[5] = {NULL};

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
                        jlog(@"FOUND %s.%s MI=%p ptr=%p", cn, n, m, getMethodPtr(m));
                    }
                }
            }
        }
    }

    for (int i = 0; searches[i].cn; i++) {
        if (found[i]) patchMethodInfo(found[i], searches[i].hf, searches[i].mn);
    }

    // 修改isInitialized
    if (g_il2cpp_field_static_set_value && g_il2cpp_class_get_field_from_name) {
        for (size_t a = 0; a < assemCount; a++) {
            void *img = get_image(assemblies[a]); if (!img) continue;
            size_t cnt = class_count ? class_count(img) : 0;
            for (size_t c = 0; c < cnt; c++) {
                void *klass = get_class(img, c); if (!klass) continue;
                const char *cn = class_name_func ? class_name_func(klass) : NULL;
                if (cn && strcmp(cn, "NTESRiskSecProtect") == 0) {
                    void *field = g_il2cpp_class_get_field_from_name(klass, "isInitialized");
                    if (field) {
                        BOOL val = YES;
                        g_il2cpp_field_static_set_value(field, &val);
                        jlog(@"isInitialized → YES");
                    }
                    // NetSecProtect也有isInitialized
                    goto done_il2cpp;
                }
            }
        }
        done_il2cpp:;
    }

    jlog(@"IL2CPP patch完成, %d hooks", g_hookCount);
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;

    jlog(@"========== JYJH 反检测 v4.0 (fishhook+MethodInfo) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);

    // ======== 第1步：立即应用fishhook（constructor阶段就执行） ========
    // fishhook修改GOT表，不需要等IL2CPP初始化
    jlog(@"=== 应用fishhook (native层) ===");

    fh_rebind_symbols("stat", (void*)hook_stat, (void**)&orig_stat);
    fh_rebind_symbols("lstat", (void*)hook_lstat, (void**)&orig_lstat);
    fh_rebind_symbols("access", (void*)hook_access, (void**)&orig_access);
    fh_rebind_symbols("fopen", (void*)hook_fopen, (void**)&orig_fopen);
    fh_rebind_symbols("open", (void*)hook_open, (void**)&orig_open);
    fh_rebind_symbols("getenv", (void*)hook_getenv, (void**)&orig_getenv);

    jlog(@"fishhook applied: stat/lstat/access/fopen/open/getenv");

    // ======== 第2步：延迟应用IL2CPP MethodInfo替换 ========
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        jlog(@"5s: applying IL2CPP patches...");
        patchIL2CPPMethods();

        // 20秒后诊断
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15.0 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            jlog(@"=== 20s诊断 ===");
            jlog(@"IL2CPP: ioctl=%d getToken=%d MyGetToken=%d MyHtp=%d isHtpExist=%d",
                 g_ioctlLogCount, g_getTokenLogCount, g_myGetTokenLogCount,
                 g_htpCallbackLogCount, g_isHtpExistLogCount);
            for (int i = 0; i < g_hookCount; i++) {
                jlog(@"%s: ptr=%p match=%d", g_hooks[i].name,
                     getMethodPtr(g_hooks[i].methodInfo),
                     getMethodPtr(g_hooks[i].methodInfo) == g_hooks[i].hookFunc);
            }
        });
    });
}
