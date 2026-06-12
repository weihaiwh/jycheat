/**
 * 剑影江湖 v27.0 - Hook OnClickSkill_6强制发送UseExSkill输入
 *
 * v26关键发现：
 * 1. OnUpdate读0x351偏移得到值65/176/224等（不是0/1），偏移错误！
 * 2. 修改非bool数据导致对象损坏，游戏卡住
 * 3. 不能直接修改UI对象内存（偏移不可靠）
 *
 * v27策略：不修改内存，用函数hook绕过怒气检查
 * 1. Hook OnClickSkill_6 → 点击大招时强制调SetInputOpt(20014,0)
 * 2. Hook SetInputOpt → 监控UseExSkill(20014)是否发送成功
 * 3. Hook DoConfirmOpt → 监控帧同步层是否收到
 * 4. 移除危险的OnUpdate内存修改
 * 5. 保留普通技能无CD + 忽略解锁 + 伤害上限
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

// BattleInputOptHelper.SetInputOpt(Int32 optType, Int32 optData) - 静态方法
typedef void (*SetInputOptFunc)(int, int);
// BattleGameLogic.DoConfirmOpt(Int32 optType, Int32 optData) - 实例方法
typedef void (*DoConfirmOptFunc)(void*, int, int);
// BattleGameLogic.OnClickSkill_6() - 实例方法
typedef void (*OnClickSkill6Func)(void*);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcTryTriggerExSkill = NULL; static BoolFunc8 g_origTryTriggerExSkill = NULL; static BOOL g_tryTriggerHooked = NO;
static void *g_funcTriggerExSkillOrAdd = NULL; static BoolFunc7 g_origTriggerExSkillOrAdd = NULL; static BOOL g_triggerOrAddHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;

// v27 hook
static void *g_funcSetInputOpt = NULL;       static SetInputOptFunc g_origSetInputOpt = NULL;       static BOOL g_setInputOptHooked = NO;
static void *g_funcDoConfirmOpt = NULL;      static DoConfirmOptFunc g_origDoConfirmOpt = NULL;     static BOOL g_doConfirmOptHooked = NO;
static void *g_funcOnClickSkill6 = NULL;     static OnClickSkill6Func g_origOnClickSkill6 = NULL;   static BOOL g_onClickSkill6Hooked = NO;

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
// v27核心: Hook OnClickSkill_6 + SetInputOpt + DoConfirmOpt
// ============================================================

// BattleInputOptHelper.SetInputOpt(Int32 optType, Int32 optData) - 静态方法
// 监控UseExSkill(20014)输入
static int g_setInputOptCount = 0;
static void hookSetInputOpt(int optType, int optData) {
    if (g_exSkillNoCD) {
        if (optType == 20014) {
            if (g_setInputOptCount < 30) {
                g_setInputOptCount++;
                jlog(@"SetInputOpt[%d] ★UseExSkill★ optData=%d", g_setInputOptCount, optData);
            }
        } else if (g_setInputOptCount < 3) {
            jlog(@"SetInputOpt type=%d data=%d", optType, optData);
        }
    }
    if (g_origSetInputOpt) g_origSetInputOpt(optType, optData);
}

// BattleGameLogic.DoConfirmOpt(Int32 optType, Int32 optData) - 实例方法
// 监控UseExSkill(20014)确认
static int g_doConfirmOptCount = 0;
static void hookDoConfirmOpt(void *self, int optType, int optData) {
    if (g_exSkillNoCD) {
        if (optType == 20014) {
            if (g_doConfirmOptCount < 30) {
                g_doConfirmOptCount++;
                jlog(@"DoConfirmOpt[%d] ★UseExSkill★ optData=%d", g_doConfirmOptCount, optData);
            }
        } else if (g_doConfirmOptCount < 3) {
            jlog(@"DoConfirmOpt type=%d data=%d", optType, optData);
        }
    }
    if (g_origDoConfirmOpt) g_origDoConfirmOpt(self, optType, optData);
}

// BattleGameLogic.OnClickSkill_6() - 玩家点击大招按钮
// 如果怒气不够UI层不会发UseExSkill，我们直接调SetInputOpt(20014,0)绕过
static int g_onClickSkill6Count = 0;
static void hookOnClickSkill6(void *self) {
    if (g_exSkillNoCD) {
        if (g_onClickSkill6Count < 30) {
            g_onClickSkill6Count++;
            jlog(@"OnClickSkill_6[%d] → 强制SetInputOpt(20014,0)", g_onClickSkill6Count);
        }
        // 先调用原始OnClickSkill_6
        if (g_origOnClickSkill6) g_origOnClickSkill6(self);
        // 然后强制发送UseExSkill输入(绕过UI层怒气检查)
        if (g_origSetInputOpt) {
            g_origSetInputOpt(20014, 0);
        }
        return;
    }
    if (g_origOnClickSkill6) g_origOnClickSkill6(self);
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
    jlog(@"=== v27.0 IL2CPP Runtime Search ===");
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
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock && cn && strcmp(cn, "CharacterFiled") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn,n,pc,funcAddr); g_funcCheckSkillUnlock=funcAddr; found++; }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcCanUseExSkill=funcAddr; found++; }
                else if (strcmp(n, "TryTriggerExSkill") == 0 && !g_funcTryTriggerExSkill) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcTryTriggerExSkill=funcAddr; found++; }
                else if (strcmp(n, "TriggerExSkillOrAdd") == 0 && !g_funcTriggerExSkillOrAdd) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcTriggerExSkillOrAdd=funcAddr; found++; }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) { jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); g_funcLimitDmg=funcAddr; found++; }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcCheckSkillIsReady && cn && strcmp(cn, "CharacterFiled") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn,n,pc,funcAddr); g_funcCheckSkillIsReady=funcAddr; found++; }
                else if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCheckSkillAttackCanUse && cn && strcmp(cn, "CharacterFiled") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn,n,pc,funcAddr); g_funcCheckSkillAttackCanUse=funcAddr; found++; }
                // v27: SetInputOpt (BattleInputOptHelper - 静态类)
                else if (strcmp(n, "SetInputOpt") == 0 && !g_funcSetInputOpt && cn && strcmp(cn, "BattleInputOptHelper") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn,n,pc,funcAddr); g_funcSetInputOpt=funcAddr; found++; }
                // v27: DoConfirmOpt (BattleGameLogic)
                else if (strcmp(n, "DoConfirmOpt") == 0 && !g_funcDoConfirmOpt && cn && strcmp(cn, "BattleGameLogic") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn,n,pc,funcAddr); g_funcDoConfirmOpt=funcAddr; found++; }
                // v27: OnClickSkill_6 (BattleGameLogic) - 玩家点击大招按钮
                else if (strcmp(n, "OnClickSkill_6") == 0 && !g_funcOnClickSkill6 && cn && strcmp(cn, "BattleGameLogic") == 0) { jlog(@"FOUND %s.%s params=%u addr=%p", cn,n,pc,funcAddr); g_funcOnClickSkill6=funcAddr; found++; }
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
        // v27: 新增hook
        if (!g_setInputOptHooked) hookOneFunc(g_funcSetInputOpt, hookSetInputOpt, (void**)&g_origSetInputOpt, &g_setInputOptHooked, "7.SetInputOpt");
        if (!g_doConfirmOptHooked) hookOneFunc(g_funcDoConfirmOpt, hookDoConfirmOpt, (void**)&g_origDoConfirmOpt, &g_doConfirmOptHooked, "8.DoConfirmOpt");
        if (!g_onClickSkill6Hooked) hookOneFunc(g_funcOnClickSkill6, hookOnClickSkill6, (void**)&g_origOnClickSkill6, &g_onClickSkill6Hooked, "9.OnClickSkill_6");
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v27.0"; title.textColor=[UIColor cyanColor];
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
    jlog(@"========== JYJH v27.0 (OnClickSkill_6强制UseExSkill) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v27核心: Hook OnClickSkill_6强制发送UseExSkill(20014)输入");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
