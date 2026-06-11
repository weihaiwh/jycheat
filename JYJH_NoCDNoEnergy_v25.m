/**
 * 剑影江湖 v25.0 - Hook UI层IsAnger + OnAngerChange
 *
 * v24关键发现：IsExSkillInCD/TriggerExSkill/DoUseExSkill hook成功但从未被调用！
 * 原因：玩家点击大招时，UI层先检查怒气(IsAnger)，不够就不发UseExSkill输入
 * 帧同步层函数根本不会被调用，所以hook帧同步层无效
 *
 * v25核心：直接hook UI层的怒气检查
 * 1. Hook UIC_FHSkillItem.set_IsAnger → 强制NO(不需要怒气)
 * 2. Hook UIC_FHSkillItem.OnAngerChange → 强制满怒气
 * 3. Hook UIC_FHSkillItem.get_IsAnger → 返回NO(不需要怒气)
 * 4. 保留普通技能无CD + 忽略解锁 + 伤害上限
 *
 * UIC_FHSkillItem字段(0x351偏移处):
 * - <IsAnger>k__BackingField: 0x351 (BOOL, 1字节)
 * - Com_anger: 0x2e8 (UIC_ProCd, 怒气进度条)
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

#include "dobby.h"

static FILE *g_logFile = NULL;
static void jlog(NSString *fmt, ...) {
    va_list args; va_start(args, fmt);
    NSString *msg = [[NSString alloc] initWithFormat:fmt arguments:args];
    va_end(args);
    NSLog(@"[JYJH] %@", msg);
    if (!g_logFile) {
        NSString *p = [NSHomeDirectory() stringByAppendingPathComponent:@"Documents/jyjh.log"];
        g_logFile = fopen([p UTF8String], "a");
    }
    if (g_logFile) { fprintf(g_logFile, "%s\n", [msg UTF8String]); fflush(g_logFile); }
}

static BOOL g_ignoreUnlock = NO;
static BOOL g_exSkillAvail = NO;
static BOOL g_exSkillNoCD = NO;
static int g_damageLimit = 100;

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);
typedef BOOL (*BoolFunc7)(void*, uint64_t, void*, uint64_t, void*, void*, int);
typedef BOOL (*BoolFunc4)(void*, int, void*, void*);

// UIC_FHSkillItem方法签名
// get_IsAnger: Boolean get_IsAnger() - 实例方法，self=x0
typedef BOOL (*IsAngerGetFunc)(void*);
// set_IsAnger: Void set_IsAnger(Boolean value) - 实例方法
typedef void (*IsAngerSetFunc)(void*, BOOL);
// OnAngerChange: Void OnAngerChange(Int32 value, Int32 count, Single elapseSeconds)
typedef void (*OnAngerChangeFunc)(void*, int32_t, int32_t, float);
// UpdateAngerPro: Void UpdateAngerPro() - 实例方法
typedef void (*UpdateAngerProFunc)(void*);
// InitAnger: Void InitAnger(Int32 Index)
typedef void (*InitAngerFunc)(void*, int32_t);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcTryTriggerExSkill = NULL; static BoolFunc8 g_origTryTriggerExSkill = NULL; static BOOL g_tryTriggerHooked = NO;
static void *g_funcTriggerExSkillOrAdd = NULL; static BoolFunc7 g_origTriggerExSkillOrAdd = NULL; static BOOL g_triggerOrAddHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;

// v25 UI层hook
static void *g_funcIsAngerGet = NULL;    static IsAngerGetFunc g_origIsAngerGet = NULL;    static BOOL g_isAngerGetHooked = NO;
static void *g_funcIsAngerSet = NULL;    static IsAngerSetFunc g_origIsAngerSet = NULL;    static BOOL g_isAngerSetHooked = NO;
static void *g_funcOnAngerChange = NULL; static OnAngerChangeFunc g_origOnAngerChange = NULL; static BOOL g_onAngerChangeHooked = NO;
static void *g_funcInitAnger = NULL;     static InitAngerFunc g_origInitAnger = NULL;      static BOOL g_initAngerHooked = NO;

// ============================================================
// Hook函数实现
// ============================================================

static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 10) { g_unlockLogCount++; jlog(@"Unlock[%d]: stateType=%d", g_unlockLogCount, a2); }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2);
    return YES;
}

static int g_canUseLogCount = 0;
static BOOL hookCanUseExSkill(void *self, int a1, int a2) {
    if (g_exSkillAvail) {
        if (g_canUseLogCount < 10) { g_canUseLogCount++; jlog(@"CanUseExSkill[%d]", g_canUseLogCount); }
        return YES;
    }
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2);
    return YES;
}

static int g_isReadyLogCount = 0;
static BOOL hookCheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_exSkillNoCD && stateType >= 17) {
        if (g_isReadyLogCount < 50) {
            g_isReadyLogCount++;
            jlog(@"IsReady[%d] stateType=%d → force YES", g_isReadyLogCount, stateType);
        }
        return YES;
    }
    if (g_origCheckSkillIsReady) return g_origCheckSkillIsReady(frame, stateType, characterField, states);
    return YES;
}

static int g_attackCanUseLogCount = 0;
static BOOL hookCheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_exSkillNoCD && stateType >= 17) {
        if (g_attackCanUseLogCount < 50) {
            g_attackCanUseLogCount++;
            jlog(@"AttackCanUse[%d] stateType=%d → force YES", g_attackCanUseLogCount, stateType);
        }
        return YES;
    }
    if (g_origCheckSkillAttackCanUse) return g_origCheckSkillAttackCanUse(frame, stateType, characterField, states);
    return YES;
}

static int g_tryTriggerLogCount = 0;
static BOOL hookTryTriggerExSkill(void *f, uint64_t type, void *trigger, void *fuse,
                                   void *targets, void *character, void *asset, uint64_t triggerData) {
    if (g_tryTriggerLogCount < 30) {
        g_tryTriggerLogCount++;
        jlog(@"TryTrigger[%d] type=%llu noCD=%d", g_tryTriggerLogCount, type, g_exSkillNoCD);
    }
    if (g_exSkillNoCD) return YES;
    if (g_origTryTriggerExSkill) return g_origTryTriggerExSkill(f, type, trigger, fuse, targets, character, asset, triggerData);
    return NO;
}

static int g_orAddLogCount = 0;
static BOOL hookTriggerExSkillOrAdd(void *f, uint64_t trigger, void *character,
                                     uint64_t now, void *info, void *asset, int lv) {
    if (g_orAddLogCount < 30) {
        g_orAddLogCount++;
        jlog(@"OrAdd[%d] noCD=%d", g_orAddLogCount, g_exSkillNoCD);
    }
    if (g_exSkillNoCD) return YES;
    if (g_origTriggerExSkillOrAdd) return g_origTriggerExSkillOrAdd(f, trigger, character, now, info, asset, lv);
    return NO;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

// ============================================================
// v25核心: Hook UI层怒气检查
// ============================================================

// get_IsAnger: 返回NO = 不是怒气技能 = 不需要怒气
// 当返回NO时，UI层不会在大招按钮上显示怒气进度条
// 玩家点击大招时不检查怒气直接发送UseExSkill输入
static int g_angerGetLogCount = 0;
static BOOL hookIsAngerGet(void *self) {
    if (g_exSkillNoCD) {
        if (g_angerGetLogCount < 20) {
            g_angerGetLogCount++;
            jlog(@"get_IsAnger[%d] → force NO(不需要怒气)", g_angerGetLogCount);
        }
        return NO; // 不需要怒气 → UI层不拦截大招点击
    }
    if (g_origIsAngerGet) return g_origIsAngerGet(self);
    return NO;
}

// set_IsAnger: 强制设为NO(不是怒气技能)
static int g_angerSetLogCount = 0;
static void hookIsAngerSet(void *self, BOOL value) {
    if (g_exSkillNoCD) {
        if (g_angerSetLogCount < 20) {
            g_angerSetLogCount++;
            jlog(@"set_IsAnger[%d] orig=%d → force NO", g_angerSetLogCount, value);
        }
        if (g_origIsAngerSet) g_origIsAngerSet(self, NO);
        return;
    }
    if (g_origIsAngerSet) g_origIsAngerSet(self, value);
}

// OnAngerChange: 怒气变化时UI更新，强制满值
// void OnAngerChange(Int32 value, Int32 count, Single elapseSeconds)
// value=当前怒气值, count=最大值
// 调用原始函数时把value设为count=满怒气
static int g_angerChgLogCount = 0;
static void hookOnAngerChange(void *self, int32_t value, int32_t count, float elapseSeconds) {
    if (g_exSkillNoCD && count > 0) {
        if (g_angerChgLogCount < 30) {
            g_angerChgLogCount++;
            jlog(@"OnAngerChange[%d] value=%d count=%d → force full(%d)", g_angerChgLogCount, value, count, count);
        }
        // 强制满怒气: value=count
        if (g_origOnAngerChange) g_origOnAngerChange(self, count, count, elapseSeconds);
        return;
    }
    if (g_origOnAngerChange) g_origOnAngerChange(self, value, count, elapseSeconds);
}

// InitAnger: 初始化怒气显示
static int g_initAngerLogCount = 0;
static void hookInitAnger(void *self, int32_t index) {
    if (g_initAngerLogCount < 10) {
        g_initAngerLogCount++;
        jlog(@"InitAnger[%d] index=%d noCD=%d", g_initAngerLogCount, index, g_exSkillNoCD);
    }
    if (g_origInitAnger) g_origInitAnger(self, index);
    // 初始化后强制设IsAnger=NO
    if (g_exSkillNoCD) {
        if (g_origIsAngerSet) g_origIsAngerSet(self, NO);
    }
}

// ============================================================
// IL2CPP运行时
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

static void findIL2CPP(void) {
    jlog(@"=== v25.0 IL2CPP Runtime Search ===");
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

    if (!domain_get || !method_name) { jlog(@"IL2CPP APIs not found"); return; }
    void *domain = domain_get();
    if (!domain) return;
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    if (!assemblies) return;
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);

    int found = 0, totalMethods = 0;
    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]); if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c); if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;
            void *iter = NULL, *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m); if (!n) continue;
                uint32_t pc = param_count ? param_count(m) : 0;
                void *funcAddr = NULL; memcpy(&funcAddr, m, sizeof(void*));
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCheckSkillUnlock=funcAddr; found++; }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCanUseExSkill=funcAddr; found++; }
                else if (strcmp(n, "TryTriggerExSkill") == 0 && !g_funcTryTriggerExSkill) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcTryTriggerExSkill=funcAddr; found++; }
                else if (strcmp(n, "TriggerExSkillOrAdd") == 0 && !g_funcTriggerExSkillOrAdd) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcTriggerExSkillOrAdd=funcAddr; found++; }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcLimitDmg=funcAddr; found++; }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcCheckSkillIsReady) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCheckSkillIsReady=funcAddr; found++; }
                else if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCheckSkillAttackCanUse) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCheckSkillAttackCanUse=funcAddr; found++; }
                // v25 UI层方法
                else if (strcmp(n, "get_IsAnger") == 0 && !g_funcIsAngerGet && cn && strcmp(cn, "UIC_FHSkillItem") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcIsAngerGet=funcAddr; found++; }
                else if (strcmp(n, "set_IsAnger") == 0 && !g_funcIsAngerSet && cn && strcmp(cn, "UIC_FHSkillItem") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcIsAngerSet=funcAddr; found++; }
                else if (strcmp(n, "OnAngerChange") == 0 && !g_funcOnAngerChange && cn && strcmp(cn, "UIC_FHSkillItem") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcOnAngerChange=funcAddr; found++; }
                else if (strcmp(n, "InitAnger") == 0 && !g_funcInitAnger && cn && strcmp(cn, "UIC_FHSkillItem") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcInitAnger=funcAddr; found++; }
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
}

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: not found", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) { *hookedFlag = YES; jlog(@"%s: OK at %p orig=%p", name, funcAddr, *origFunc); }
    else { jlog(@"%s: FAILED ret=%d", name, ret); }
}

static void applyAllHooks(void) {
    if (!g_funcCheckSkillUnlock) findIL2CPP();
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "3.伤害上限");
    jlog(@"applyAllHooks done");
}

// ============================================================
// UI
// ============================================================

static UIView *g_panel = nil;
static UIButton *g_btnIgnoreUnlock = nil;
static UIButton *g_btnExSkillAvail = nil;
static UIButton *g_btnExSkillNoCD = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static void refreshButtons(void) {
    [g_btnIgnoreUnlock setTitle: g_ignoreUnlock ? @"\U00002705 \u5ffd\u7565\u89e3\u9501" : @"\U0000274c \u5ffd\u7565\u89e3\u9501" forState:UIControlStateNormal];
    g_btnIgnoreUnlock.backgroundColor = g_ignoreUnlock ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnExSkillAvail setTitle: g_exSkillAvail ? @"\U00002705 \u5927\u62db\u53ef\u7528" : @"\U0000274c \u5927\u62db\u53ef\u7528" forState:UIControlStateNormal];
    g_btnExSkillAvail.backgroundColor = g_exSkillAvail ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnExSkillNoCD setTitle: g_exSkillNoCD ? @"\U00002705 \u6012\u6c14\u52a0\u6ee1" : @"\U0000274c \u6012\u6c14\u52a0\u6ee1" forState:UIControlStateNormal];
    g_btnExSkillNoCD.backgroundColor = g_exSkillNoCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=240;
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
- (void)onIgnoreUnlock;
- (void)onExSkillAvail;
- (void)onExSkillNoCD;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onIgnoreUnlock {
    g_ignoreUnlock=!g_ignoreUnlock;
    if (g_ignoreUnlock && !g_skillUnlockHooked) { findIL2CPP(); hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "1.忽略解锁"); }
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock);
}
- (void)onExSkillAvail {
    g_exSkillAvail=!g_exSkillAvail;
    if (g_exSkillAvail && !g_canUseExSkillHooked) { findIL2CPP(); hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "2.大招可用"); }
    refreshButtons(); jlog(@"Toggle 大招可用: %d", g_exSkillAvail);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        if (!g_tryTriggerHooked) hookOneFunc(g_funcTryTriggerExSkill, hookTryTriggerExSkill, (void**)&g_origTryTriggerExSkill, &g_tryTriggerHooked, "4a.TryTrigger");
        if (!g_triggerOrAddHooked) hookOneFunc(g_funcTriggerExSkillOrAdd, hookTriggerExSkillOrAdd, (void**)&g_origTriggerExSkillOrAdd, &g_triggerOrAddHooked, "4b.OrAdd");
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "5.IsReady");
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "6.AttackCanUse");
        // v25 UI层hook
        if (!g_isAngerGetHooked) hookOneFunc(g_funcIsAngerGet, hookIsAngerGet, (void**)&g_origIsAngerGet, &g_isAngerGetHooked, "7.get_IsAnger→NO");
        if (!g_isAngerSetHooked) hookOneFunc(g_funcIsAngerSet, hookIsAngerSet, (void**)&g_origIsAngerSet, &g_isAngerSetHooked, "8.set_IsAnger→NO");
        if (!g_onAngerChangeHooked) hookOneFunc(g_funcOnAngerChange, hookOnAngerChange, (void**)&g_origOnAngerChange, &g_onAngerChangeHooked, "9.OnAngerChange→full");
        if (!g_initAngerHooked) hookOneFunc(g_funcInitAnger, hookInitAnger, (void**)&g_origInitAnger, &g_initAngerHooked, "10.InitAnger");
    }
    refreshButtons(); jlog(@"Toggle 怒气加满: %d", g_exSkillNoCD);
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
            if (scene.activationState == UISceneActivationStateForegroundActive && [scene isKindOfClass:[UIWindowScene class]]) {
                for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (w.isKeyWindow && !w.isHidden) return w; }
                for (UIWindow *w in ((UIWindowScene *)scene).windows) { if (!w.isHidden) return w; }
            }
        }
    }
    for (UIWindow *w in [UIApplication sharedApplication].windows) { if (w.isKeyWindow && !w.isHidden) return w; }
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];
    CGFloat pw=260, ph=240;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,8,pw,22)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v25.0"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:14]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    CGFloat bx=16, bw=228, bh=32, by0=34, bdy=36;
    g_btnIgnoreUnlock=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnIgnoreUnlock.frame=CGRectMake(bx,by0,bw,bh);
    g_btnIgnoreUnlock.layer.cornerRadius=8; g_btnIgnoreUnlock.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnIgnoreUnlock addTarget:[JYJHActionHandler shared] action:@selector(onIgnoreUnlock) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnIgnoreUnlock];
    g_btnExSkillAvail=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillAvail.frame=CGRectMake(bx,by0+bdy,bw,bh);
    g_btnExSkillAvail.layer.cornerRadius=8; g_btnExSkillAvail.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillAvail addTarget:[JYJHActionHandler shared] action:@selector(onExSkillAvail) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillAvail];
    g_btnExSkillNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillNoCD.frame=CGRectMake(bx,by0+bdy*2,bw,bh);
    g_btnExSkillNoCD.layer.cornerRadius=8; g_btnExSkillNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillNoCD addTarget:[JYJHActionHandler shared] action:@selector(onExSkillNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillNoCD];
    CGFloat sy = by0 + bdy*3 + 4;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d", g_damageLimit];
    g_sliderLabel.textColor=[UIColor whiteColor]; g_sliderLabel.font=[UIFont systemFontOfSize:12]; [g_panel addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=30000; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    jlog(@"========== JYJH v25.0 (Hook UI层IsAnger!) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v25核心: Hook UIC_FHSkillItem.IsAnger/OnAngerChange");
    jlog(@"v24发现: 帧同步层函数从未被调用，UI层先检查怒气");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
