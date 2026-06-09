/**
 * 剑影江湖 v11.0 - IL2CPP方法扫描 + Dobby Hook
 * 
 * v10.0问题:
 *   1. CheckSkillIsReady hook返回true, 但大招仍提示"怒气不足"
 *      → 大招可能有单独的校验函数, 不走CheckSkillIsReady
 *      → 或者有级别校验(30级解锁大招)
 *   2. 新版本改为技能命中敌人才涨怒气
 *      → 需要找到怒气增加相关函数
 *   3. get_limitDamage是全局的, 怪物伤害也变高
 *      → 需要找到区分攻击者的伤害计算函数
 * 
 * v11.0方案:
 *   第一步: 扫描IL2CPP所有方法名, dump到日志文件
 *     - 搜索关键词: anger/rage/fury/怒气/energy/mp/怒
 *     - 搜索关键词: level/unlock/级别/等级
 *     - 搜索关键词: damage/attack/hit/伤害
 *     - 搜索关键词: skill/ultimate/大招/绝招
 *   第二步: 根据扫描结果, 增加新的hook点
 *   第三步: 伤害修改区分攻击者(只对玩家角色生效)
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

// Dobby框架头文件
#include "dobby.h"

// ============================================================
// 日志系统
// ============================================================

static FILE *g_logFile = NULL;
static FILE *g_dumpFile = NULL;  // 方法名dump文件
static NSMutableArray *g_debugLines = nil;
static UILabel *g_debugLabel = nil;

static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (g_debugLines) { [g_debugLines addObject:msg]; if(g_debugLines.count>30)[g_debugLines removeObjectAtIndex:0]; }
    if (g_debugLabel) g_debugLabel.text = [g_debugLines componentsJoinedByString:@"\n"];
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([p UTF8String], "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

// ============================================================
// 全局状态
// ============================================================

static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static BOOL g_noAnger = YES;   // 无限怒气 (新)
static int g_damageLimit = 10000;

// IL2CPP MethodInfo指针
static void *g_infoCanUse = NULL;
static void *g_infoIsReady = NULL;
static void *g_infoLimitDmg = NULL;

// 原始函数地址 (从MethodInfo.methodPointer读出)
static void *g_funcCanUse = NULL;
static void *g_funcIsReady = NULL;
static void *g_funcLimitDmg = NULL;

// Dobby hook后的原始函数指针 (调用trampoline)
typedef BOOL (*CanUseFuncType)(void *self, int a1, int a2, int a3);
static CanUseFuncType g_origCanUse = NULL;

typedef BOOL (*IsReadyFuncType)(void *self, int a1, int a2, int a3);
static IsReadyFuncType g_origIsReady = NULL;

typedef int (*LimitDmgFuncType)(void *self);
static LimitDmgFuncType g_origLimitDmg = NULL;

// Hook状态
static BOOL g_cdHooked = NO;
static BOOL g_energyHooked = NO;
static BOOL g_limitHooked = NO;
static BOOL g_angerHooked = NO;

// v11扫描发现的新hook目标 (动态发现, 数组存储)
#define MAX_EXTRA_HOOKS 32
typedef struct {
    char methodName[128];
    char className[128];
    void *funcAddr;
    void *origFunc;
    BOOL hooked;
} ExtraHookEntry;

static ExtraHookEntry g_extraHooks[MAX_EXTRA_HOOKS];
static int g_extraHookCount = 0;

// UI
static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UIButton *g_btnAnger = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

// ============================================================
// 替代函数 (Dobby hook的目标函数)
// ============================================================

static BOOL hookCanUse(void *self, int a1, int a2, int a3) {
    if (g_noCD) return YES;
    if (g_origCanUse) return g_origCanUse(self, a1, a2, a3);
    return YES;
}

static BOOL hookIsReady(void *self, int a1, int a2, int a3) {
    if (g_noEnergy) {
        jlog(@"IsReady→true skill=%d", a1);
        return YES;
    }
    if (g_origIsReady) return g_origIsReady(self, a1, a2, a3);
    return YES;
}

static int hookLimitDmg(void *self) {
    return g_damageLimit;
}

/**
 * 通用bool hook: 返回true
 * 用于所有发现的怒气/大招/级别检查函数
 */
static BOOL hookReturnTrue(void *self, int a1, int a2, int a3) {
    // 遍历找到匹配的origFunc
    for (int i = 0; i < g_extraHookCount; i++) {
        if (g_extraHooks[i].hooked && g_extraHooks[i].origFunc) {
            // 简单策略: 如果g_noAnger=YES, 所有额外hook都返回true
            if (g_noAnger) {
                jlog(@"hookReturnTrue: %s → true", g_extraHooks[i].methodName);
                return YES;
            }
            return ((BOOL(*)(void*,int,int,int))g_extraHooks[i].origFunc)(self, a1, a2, a3);
        }
    }
    return YES;
}

/**
 * 通用int hook: 怒气增加放大
 * 用于AddAnger/OnHit等函数, 让怒气增加100倍
 */
static int hookAddAngerAmplify(void *self, int a1, int a2, int a3) {
    if (g_noAnger && a1 > 0) {
        jlog(@"AddAnger amplified: %d → %d", a1, a1 * 100);
        // 找到origFunc
        for (int i = 0; i < g_extraHookCount; i++) {
            if (g_extraHooks[i].hooked && g_extraHooks[i].origFunc) {
                return ((int(*)(void*,int,int,int))g_extraHooks[i].origFunc)(self, a1 * 100, a2, a3);
            }
        }
    }
    // 不放大时调用原函数
    for (int i = 0; i < g_extraHookCount; i++) {
        if (g_extraHooks[i].hooked && g_extraHooks[i].origFunc) {
            return ((int(*)(void*,int,int,int))g_extraHooks[i].origFunc)(self, a1, a2, a3);
        }
    }
    return a1;
}

// ============================================================
// IL2CPP运行时API类型定义
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

// ============================================================
// 方法名关键词匹配
// v11核心: 搜索所有可能与怒气/大招/级别/伤害相关的方法
// ============================================================

/**
 * 判断方法名是否包含怒气/大招相关关键词
 * 返回: 0=不匹配, 1=怒气检查(返回true hook), 2=怒气增加(放大hook), 3=伤害计算
 */
static int matchAngerKeyword(const char *name) {
    if (!name) return 0;
    
    // 怒气/愤怒相关 (中文游戏常见)
    // anger, rage, fury, 怒气, 怒, 狂暴
    if (strstr(name, "Anger") || strstr(name, "anger") ||
        strstr(name, "Rage") || strstr(name, "rage") ||
        strstr(name, "Fury") || strstr(name, "fury") ||
        strstr(name, "anger")) {
        // 区分是"检查"还是"增加"
        if (strstr(name, "Check") || strstr(name, "check") ||
            strstr(name, "Can") || strstr(name, "can") ||
            strstr(name, "Is") || strstr(name, "is") ||
            strstr(name, "Has") || strstr(name, "has") ||
            strstr(name, "Enough") || strstr(name, "enough") ||
            strstr(name, "Ready") || strstr(name, "ready") ||
            strstr(name, "Enough") || strstr(name, "enough")) {
            return 1;  // 检查类 → 返回true
        }
        if (strstr(name, "Add") || strstr(name, "add") ||
            strstr(name, "Gain") || strstr(name, "gain") ||
            strstr(name, "Increase") || strstr(name, "increase") ||
            strstr(name, "OnHit") || strstr(name, "onHit") ||
            strstr(name, "OnSkillHit") || strstr(name, "OnAttack") ||
            strstr(name, "Set") || strstr(name, "set")) {
            return 2;  // 增加类 → 放大
        }
        return 1;  // 默认当检查类
    }
    
    // 大招/终极技能
    if (strstr(name, "Ultimate") || strstr(name, "ultimate") ||
        strstr(name, "Ult") || strstr(name, "ult") ||
        strstr(name, "UltSkill") || strstr(name, "BigSkill") ||
        strstr(name, "SpecialSkill") || strstr(name, "UniqueSkill")) {
        return 1;  // 检查类
    }
    
    // 能量/MP (除CheckSkillIsReady之外的)
    if (strstr(name, "Energy") || strstr(name, "energy") ||
        strstr(name, "Mana") || strstr(name, "mana") ||
        strstr(name, "Mp") || strstr(name, "MP")) {
        if (strstr(name, "Check") || strstr(name, "Can") ||
            strstr(name, "Is") || strstr(name, "Enough") ||
            strstr(name, "Ready") || strstr(name, "Cost")) {
            return 1;  // 检查类
        }
        if (strstr(name, "Add") || strstr(name, "Gain") ||
            strstr(name, "Increase") || strstr(name, "Set") ||
            strstr(name, "Recover") || strstr(name, "Regen")) {
            return 2;  // 增加类
        }
    }
    
    // 级别/解锁相关
    if (strstr(name, "Level") || strstr(name, "level") ||
        strstr(name, "Unlock") || strstr(name, "unlock")) {
        if (strstr(name, "Check") || strstr(name, "Can") ||
            strstr(name, "Is") || strstr(name, "Enough") ||
            strstr(name, "Unlock") || strstr(name, "Require")) {
            return 1;  // 检查类
        }
    }
    
    // 伤害计算 (区分攻击者)
    if (strstr(name, "Damage") || strstr(name, "damage") ||
        strstr(name, "Attack") || strstr(name, "attack") ||
        strstr(name, "Hit") || strstr(name, "hit")) {
        if (strstr(name, "Calc") || strstr(name, "calc") ||
            strstr(name, "Compute") || strstr(name, "compute") ||
            strstr(name, "Get") || strstr(name, "get") ||
            strstr(name, "Apply") || strstr(name, "apply") ||
            strstr(name, "Deal") || strstr(name, "deal") ||
            strstr(name, "Take") || strstr(name, "take")) {
            return 3;  // 伤害计算
        }
    }
    
    // 技能相关 (更宽泛的搜索)
    if (strstr(name, "Skill") || strstr(name, "skill")) {
        if (strstr(name, "CanUse") || strstr(name, "CanCast") ||
            strstr(name, "IsReady") || strstr(name, "IsAvailable") ||
            strstr(name, "CheckCost") || strstr(name, "CheckRequire")) {
            return 1;  // 检查类
        }
    }
    
    return 0;
}

/**
 * 判断方法名是否值得dump (不匹配关键词但也可能是相关的)
 */
static BOOL shouldDumpMethod(const char *name) {
    if (!name) return NO;
    
    // 所有CharacterFiled类的方法
    if (strstr(name, "Skill") || strstr(name, "skill") ||
        strstr(name, "Attack") || strstr(name, "attack") ||
        strstr(name, "Damage") || strstr(name, "damage") ||
        strstr(name, "Hit") || strstr(name, "hit") ||
        strstr(name, "Anger") || strstr(name, "anger") ||
        strstr(name, "Rage") || strstr(name, "rage") ||
        strstr(name, "Energy") || strstr(name, "energy") ||
        strstr(name, "Level") || strstr(name, "level") ||
        strstr(name, "Ult") || strstr(name, "ult") ||
        strstr(name, "Check") || strstr(name, "check") ||
        strstr(name, "Can") || strstr(name, "can") ||
        strstr(name, "Cost") || strstr(name, "cost") ||
        strstr(name, "Ready") || strstr(name, "ready") ||
        strstr(name, "Limit") || strstr(name, "limit") ||
        strstr(name, "Power") || strstr(name, "power") ||
        strstr(name, "Force") || strstr(name, "force") ||
        strstr(name, "Mp") || strstr(name, "MP") ||
        strstr(name, "Unlock") || strstr(name, "unlock") ||
        strstr(name, "Require") || strstr(name, "require") ||
        strstr(name, "Add") || strstr(name, "Gain") ||
        strstr(name, "Combat") || strstr(name, "combat") ||
        strstr(name, "Battle") || strstr(name, "battle") ||
        strstr(name, "Fight") || strstr(name, "fight") ||
        strstr(name, "Cast") || strstr(name, "cast")) {
        return YES;
    }
    return NO;
}

// ============================================================
// 查找IL2CPP方法 + 方法名扫描
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v11.0 IL2CPP Runtime Search + Method Scan ===");
    
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
    Il2CppClassGetName class_name = dlsym(h, "il2cpp_class_get_name");
    
    jlog(@"APIs: domain=%p assemblies=%p image=%p class_count=%p class=%p methods=%p name=%p",
         domain_get, get_assemblies, get_image, class_count, get_class, get_methods, method_name);
    
    if (!domain_get || !method_name) {
        jlog(@"IL2CPP APIs not found");
        return;
    }
    
    void *domain = domain_get();
    jlog(@"domain=%p", domain);
    if (!domain) return;
    
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);
    if (!assemblies) return;
    
    // 打开dump文件
    if (!g_dumpFile) {
        NSString *dp = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh_methods.txt"];
        g_dumpFile = fopen([dp UTF8String], "w");
        if (g_dumpFile) jlog(@"Dump file opened: %@", dp);
    }
    
    int found = 0;
    int totalMethods = 0;
    int matchedMethods = 0;
    int dumpMethods = 0;
    
    // 扫描所有assembly, 不限found数量 (v11: 完整扫描)
    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            const char *cn = class_name ? class_name(klass) : NULL;
            
            void *iter = NULL;
            void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;
                
                uint32_t pc = param_count ? param_count(m) : 0;
                
                // 1. 原有3个hook目标
                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_infoCanUse) {
                    jlog(@"FOUND CheckSkillAttackCanUse class=%s params=%u", cn ?: "?", pc);
                    g_infoCanUse = m;
                    memcpy(&g_funcCanUse, m, sizeof(void*));
                    jlog(@"  funcAddr=%p", g_funcCanUse);
                    found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_infoIsReady) {
                    jlog(@"FOUND CheckSkillIsReady class=%s params=%u", cn ?: "?", pc);
                    g_infoIsReady = m;
                    memcpy(&g_funcIsReady, m, sizeof(void*));
                    jlog(@"  funcAddr=%p", g_funcIsReady);
                    found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_infoLimitDmg) {
                    jlog(@"FOUND get_limitDamage class=%s params=%u", cn ?: "?", pc);
                    g_infoLimitDmg = m;
                    memcpy(&g_funcLimitDmg, m, sizeof(void*));
                    jlog(@"  funcAddr=%p", g_funcLimitDmg);
                    found++;
                }
                
                // 2. v11: 关键词匹配 - 怒气/大招/级别相关
                int matchType = matchAngerKeyword(n);
                if (matchType > 0 && g_extraHookCount < MAX_EXTRA_HOOKS) {
                    void *funcAddr = NULL;
                    memcpy(&funcAddr, m, sizeof(void*));
                    
                    jlog(@"MATCH[%d] %s.%s params=%u addr=%p type=%d",
                         g_extraHookCount, cn ?: "?", n, pc, funcAddr, matchType);
                    
                    if (g_dumpFile) {
                        fprintf(g_dumpFile, "MATCH[%d] type=%d %s.%s params=%u addr=%p\n",
                                g_extraHookCount, matchType, cn ?: "?", n, pc, funcAddr);
                    }
                    
                    // 保存到extraHooks数组
                    ExtraHookEntry *entry = &g_extraHooks[g_extraHookCount];
                    memset(entry, 0, sizeof(ExtraHookEntry));
                    strncpy(entry->methodName, n, sizeof(entry->methodName) - 1);
                    if (cn) strncpy(entry->className, cn, sizeof(entry->className) - 1);
                    entry->funcAddr = funcAddr;
                    entry->hooked = NO;
                    g_extraHookCount++;
                    matchedMethods++;
                }
                
                // 3. v11: dump所有相关方法名到文件
                if (shouldDumpMethod(n)) {
                    if (g_dumpFile) {
                        void *faddr = NULL;
                        memcpy(&faddr, m, sizeof(void*));
                        fprintf(g_dumpFile, "DUMP %s.%s params=%u addr=%p\n",
                                cn ?: "?", n, pc, faddr);
                        dumpMethods++;
                    }
                }
            }
        }
    }
    
    // 关闭dump文件
    if (g_dumpFile) {
        fprintf(g_dumpFile, "\n=== SCAN SUMMARY ===\n");
        fprintf(g_dumpFile, "Total methods scanned: %d\n", totalMethods);
        fprintf(g_dumpFile, "Keyword matched: %d\n", matchedMethods);
        fprintf(g_dumpFile, "Dumped (broader match): %d\n", dumpMethods);
        fprintf(g_dumpFile, "Extra hooks to try: %d\n", g_extraHookCount);
        fclose(g_dumpFile);
        g_dumpFile = NULL;
    }
    
    jlog(@"Scanned %d methods, found %d primary, %d keyword matches, %d dumped",
         totalMethods, found, matchedMethods, dumpMethods);
    jlog(@"FuncAddr: CanUse=%p IsReady=%p LimitDmg=%p",
         g_funcCanUse, g_funcIsReady, g_funcLimitDmg);
    
    // 打印所有发现的新方法
    jlog(@"=== Extra Hook Targets (%d) ===", g_extraHookCount);
    for (int i = 0; i < g_extraHookCount; i++) {
        jlog(@"  [%d] %s.%s addr=%p",
             i, g_extraHooks[i].className, g_extraHooks[i].methodName, g_extraHooks[i].funcAddr);
    }
}

// ============================================================
// Dobby Hook 操作
// ============================================================

static void hookCanUseFunc(BOOL enable) {
    if (!g_funcCanUse) { jlog(@"CanUse: funcAddr not found"); return; }
    
    if (!g_cdHooked) {
        int ret = DobbyHook(g_funcCanUse, hookCanUse, (void **)&g_origCanUse);
        if (ret == 0) {
            g_cdHooked = YES;
            jlog(@"CanUse: DobbyHook OK at %p, orig=%p", g_funcCanUse, g_origCanUse);
        } else {
            jlog(@"CanUse: DobbyHook FAILED ret=%d addr=%p", ret, g_funcCanUse);
        }
    }
    jlog(@"CanUse: g_noCD=%d", g_noCD);
}

static void hookIsReadyFunc(BOOL enable) {
    if (!g_funcIsReady) { jlog(@"IsReady: funcAddr not found"); return; }
    
    if (!g_energyHooked) {
        int ret = DobbyHook(g_funcIsReady, hookIsReady, (void **)&g_origIsReady);
        if (ret == 0) {
            g_energyHooked = YES;
            jlog(@"IsReady: DobbyHook OK at %p, orig=%p", g_funcIsReady, g_origIsReady);
        } else {
            jlog(@"IsReady: DobbyHook FAILED ret=%d addr=%p", ret, g_funcIsReady);
        }
    }
    jlog(@"IsReady: g_noEnergy=%d", g_noEnergy);
}

static void hookLimitDmgFunc(BOOL enable) {
    if (!g_funcLimitDmg) { jlog(@"LimitDmg: funcAddr not found"); return; }
    
    if (!g_limitHooked) {
        int ret = DobbyHook(g_funcLimitDmg, hookLimitDmg, (void **)&g_origLimitDmg);
        if (ret == 0) {
            g_limitHooked = YES;
            jlog(@"LimitDmg: DobbyHook OK at %p, orig=%p", g_funcLimitDmg, g_origLimitDmg);
        } else {
            jlog(@"LimitDmg: DobbyHook FAILED ret=%d addr=%p", ret, g_funcLimitDmg);
        }
    }
    jlog(@"LimitDmg: g_damageLimit=%d", g_damageLimit);
}

/**
 * v11: 对所有发现的怒气/大招/级别相关函数做Dobby hook
 * type=1的用hookReturnTrue, type=2的用hookAddAngerAmplify
 */
static void hookExtraAngerFuncs(void) {
    int hooked = 0;
    for (int i = 0; i < g_extraHookCount; i++) {
        ExtraHookEntry *entry = &g_extraHooks[i];
        if (entry->hooked || !entry->funcAddr) continue;
        
        // 对所有检查类(type=1)和增加类(type=2)的函数做hook
        // 注意: 伤害计算类(type=3)暂不自动hook, 先观察
        if (entry->funcAddr == g_funcCanUse || entry->funcAddr == g_funcIsReady || entry->funcAddr == g_funcLimitDmg) {
            jlog(@"Skip [%d] %s - already hooked as primary", i, entry->methodName);
            continue;
        }
        
        // 只hook type=1(检查类)的函数, type=2(增加类)暂不hook
        // 因为hookAddAngerAmplify用了通用函数, 可能会影响逻辑
        // 先只做"返回true"类hook, 安全性更高
        int matchType = matchAngerKeyword(entry->methodName);
        if (matchType == 1) {
            int ret = DobbyHook(entry->funcAddr, hookReturnTrue, &entry->origFunc);
            if (ret == 0) {
                entry->hooked = YES;
                hooked++;
                jlog(@"ExtraHook[%d] OK: %s.%s addr=%p orig=%p (return true)",
                     i, entry->className, entry->methodName, entry->funcAddr, entry->origFunc);
            } else {
                jlog(@"ExtraHook[%d] FAILED: %s ret=%d", i, entry->methodName, ret);
            }
        } else if (matchType == 2) {
            // 增加类: 先不自动hook, 只记录
            jlog(@"ExtraHook[%d] SKIP (amplify type): %s.%s - not auto-hooked for safety",
                 i, entry->className, entry->methodName);
        } else if (matchType == 3) {
            // 伤害计算类: 先不hook, 需要更多分析
            jlog(@"ExtraHook[%d] SKIP (damage calc): %s.%s - needs analysis",
                 i, entry->className, entry->methodName);
        }
    }
    jlog(@"hookExtraAngerFuncs: %d new hooks applied", hooked);
}

static void applyAllHooks(void) {
    if (!g_infoCanUse) findIL2CPP();
    
    if (g_noCD) hookCanUseFunc(YES);
    if (g_noEnergy) hookIsReadyFunc(YES);
    hookLimitDmgFunc(YES);
    
    // v11: hook所有发现的怒气/大招相关函数
    if (g_noAnger) hookExtraAngerFuncs();
    
    jlog(@"applyAllHooks done (v11.0 - Dobby + method scan)");
}

// ============================================================
// UI
// ============================================================

static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"\U00002705 \u65e0CD: \u5f00" : @"\U0000274c \u65e0CD: \u5173" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"\U00002705 \u65e0\u80fd\u91cf: \u5f00" : @"\U0000274c \u65e0\u80fd\u91cf: \u5173" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnAnger setTitle: g_noAnger ? @"\U00002705 \u65e0\u9650\u6012\u6c14: \u5f00" : @"\U0000274c \u65e0\u9650\u6012\u6c14: \u5173" forState:UIControlStateNormal];
    g_btnAnger.backgroundColor = g_noAnger ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=440;
    CGFloat px=bf.origin.x-pw-8; if(px<4)px=bf.origin.x+bf.size.width+8;
    CGFloat py=bf.origin.y+bf.size.height/2-ph/2;
    if(py<4)py=4; if(py+ph>sc.size.height-4)py=sc.size.height-ph-4;
    g_panel.frame=CGRectMake(px,py,pw,ph);
}

static void togglePanel(UIView *bv) {
    g_panelOpen=!g_panelOpen; g_panel.hidden=!g_panelOpen;
    if(g_panelOpen)layoutPanel(bv);
}

@interface JYJHActionHandler : NSObject
+ (instancetype)shared;
- (void)onCD;
- (void)onEnergy;
- (void)onAnger;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onCD {
    g_noCD=!g_noCD; refreshButtons();
    jlog(@"Toggle CD: %d", g_noCD);
}
- (void)onEnergy {
    g_noEnergy=!g_noEnergy; refreshButtons();
    jlog(@"Toggle Energy: %d", g_noEnergy);
}
- (void)onAnger {
    g_noAnger=!g_noAnger; refreshButtons();
    jlog(@"Toggle Anger: %d (affects %d extra hooks)", g_noAnger, g_extraHookCount);
}
- (void)sliderChanged:(UISlider *)s {
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d",g_damageLimit];
}
@end

@interface JYJHBallView : UIView { CGPoint _ts; BOOL _drag; }
@end
@implementation JYJHBallView
- (instancetype)init {
    self=[super initWithFrame:CGRectMake([UIScreen mainScreen].bounds.size.width-54,100,44,44)];
    if(self){self.backgroundColor=[UIColor colorWithRed:0.1 green:0.5 blue:0.95 alpha:0.9];self.layer.cornerRadius=22;self.userInteractionEnabled=YES;
    UILabel*l=[[UILabel alloc]initWithFrame:CGRectMake(0,0,44,44)];l.text=@"\u5251";l.textColor=[UIColor whiteColor];l.font=[UIFont boldSystemFontOfSize:18];l.textAlignment=NSTextAlignmentCenter;[self addSubview:l];}
    return self;
}
- (BOOL)pointInside:(CGPoint)p withEvent:(UIEvent*)e{return CGRectContainsPoint(CGRectInset(self.bounds,-8,-8),p);}
- (void)touchesBegan:(NSSet*)t withEvent:(UIEvent*)e{_ts=[[t anyObject]locationInView:self.superview];_drag=NO;}
- (void)touchesMoved:(NSSet*)t withEvent:(UIEvent*)e{CGPoint c=[[t anyObject]locationInView:self.superview];CGFloat dx=c.x-_ts.x,dy=c.y-_ts.y;if(fabs(dx)>5||fabs(dy)>5){_drag=YES;CGRect f=self.frame;CGRect sc=[UIScreen mainScreen].bounds;f.origin.x=MAX(0,MIN(sc.size.width-f.size.width,f.origin.x+dx));f.origin.y=MAX(50,MIN(sc.size.height-f.size.height-50,f.origin.y+dy));self.frame=f;_ts=c;if(g_panelOpen)layoutPanel(self);}}
- (void)touchesEnded:(NSSet*)t withEvent:(UIEvent*)e{if(!_drag)togglePanel(self);_drag=NO;}
- (void)touchesCancelled:(NSSet*)t withEvent:(UIEvent*)e{_drag=NO;}
@end

static UIWindow *getKeyWindow(void) {
    if (@available(iOS 15.0, *)) {
        for (UIScene *scene in [UIApplication sharedApplication].connectedScenes) {
            if (scene.activationState == UISceneActivationStateForegroundActive &&
                [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (w.isKeyWindow && !w.isHidden) return w;
                }
                for (UIWindow *w in ((UIWindowScene *)scene).windows) {
                    if (!w.isHidden) return w;
                }
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (w.isKeyWindow && !w.isHidden) return w;
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden) return w;
    }
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,440)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v11.0 (Scan)"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:15]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    g_btnCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8; [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnCD];
    g_btnEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8; [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnEnergy];
    // v11: 新增无限怒气按钮
    g_btnAnger=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnAnger.frame=CGRectMake(16,126,228,36);
    g_btnAnger.layer.cornerRadius=8; [g_btnAnger addTarget:[JYJHActionHandler shared] action:@selector(onAnger) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnAnger];
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(16,170,228,20)];
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d", g_damageLimit]; g_sliderLabel.textColor=[UIColor whiteColor];
    g_sliderLabel.font=[UIFont systemFontOfSize:13]; [g_panel addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(16,192,228,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=10000; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    g_debugLabel=[[UILabel alloc]initWithFrame:CGRectMake(8,228,244,200)];
    g_debugLabel.textColor=[UIColor colorWithRed:0.2 green:1.0 blue:0.2 alpha:1.0];
    g_debugLabel.font=[UIFont fontWithName:@"Menlo" size:10]; g_debugLabel.numberOfLines=0; [g_panel addSubview:g_debugLabel];
    refreshButtons();
}

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) { jlog(@"Already loaded, skip"); return; }
    loaded = YES;
    
    g_debugLines=[NSMutableArray new];
    jlog(@"========== JYJH v11.0 (Scan + Dobby) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"Strategy: IL2CPP method scan + Dobby hook");
    
    // 延迟5秒, 等IL2CPP运行时初始化完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, scanning methods + applying hooks...");
        applyAllHooks();
        
        // 等3秒后再显示UI (让scan和hook先完成)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
