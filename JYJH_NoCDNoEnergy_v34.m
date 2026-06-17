/**
 * 剑影江湖 v34.0 - 玩家不死(学习逻辑放AttackCanUse) + 修复互秒
 *
 * v33问题: learned=0, 没有CFDump日志 → CheckSkillIsReady从未被调用!
 *   GodMode学习逻辑放在IsReady里, 但IsReady非战斗时不调用
 *   v32证明AttackCanUse才被频繁调用, 但v33的AttackCanUse没有学习逻辑
 *
 * v34修复:
 *   1. dumpCF+isPlayerCF学习逻辑放到AttackCanUse(频繁调用)
 *   2. AttackCanUse不管g_exSkillNoCD, 只要g_godMode就执行学习+GodMode
 *   3. 每次AttackCanUse都打印调试(前30次)
 *   4. limitDamage默认改回100(避免互秒), 用户可调滑块到30000秒杀
 *   5. IsReady默认返回值改回调用原始函数(不返回NO)
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

// Toggle flags
static BOOL g_ignoreUnlock = NO;
static BOOL g_exSkillNoCD = NO;
static BOOL g_godMode = NO;
static int g_damageLimit = 100;  // v34: 默认100, 用户可调到30000秒杀

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*, int, void*, void*);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;

static void *g_playerCF = NULL;
static BOOL g_playerCFLearned = NO;

// v34: isPlayerCF尝试多个偏移
// dump.cs偏移含0x10虚拟header, 实际偏移=dump-0x10
// IsAI dump=0x54 → 实际0x44, 但也可能就是0x54(不一定都减0x10)
// Camp dump=0x34 → 实际0x24
static int g_isPlayerLogCount = 0;

static BOOL isPlayerCF(void *cf) {
    if (!cf) return NO;
    // 尝试所有可能的IsAI偏移
    int32_t v44 = -1, v54 = -1, v64 = -1;
    memcpy(&v44, (uint8_t*)cf + 0x44, 4);
    memcpy(&v54, (uint8_t*)cf + 0x54, 4);
    memcpy(&v64, (uint8_t*)cf + 0x64, 4);
    // 玩家: IsAI==0
    if (v44 == 0 || v54 == 0 || v64 == 0) return YES;
    return NO;
}

static void makePlayerGodMode(void *cf) {
    if (!cf) return;
    // Invincible=1 (尝试CF+0x00和CF+0x10)
    uint8_t inv = 1;
    memcpy((uint8_t*)cf + 0x00, &inv, 1);
    memcpy((uint8_t*)cf + 0x10, &inv, 1);

    // RealAttr满血 (多组偏移都写)
    int64_t hugeHp = 99999999LL;
    // dump偏移0x2b0-0x10=0x2a0: cur_hp(0x88) hp(0x90)
    memcpy((uint8_t*)cf + 0x328, &hugeHp, 8);  // 0x2a0+0x88
    memcpy((uint8_t*)cf + 0x330, &hugeHp, 8);  // 0x2a0+0x90
    // dump偏移0x2b0(不减0x10): cur_hp(0x98) hp(0xa0)
    memcpy((uint8_t*)cf + 0x348, &hugeHp, 8);  // 0x2b0+0x98
    memcpy((uint8_t*)cf + 0x350, &hugeHp, 8);  // 0x2b0+0xa0
    // Attribute dump偏移0x368-0x10=0x358: cur_hp(0x98) hp(0xa0)
    memcpy((uint8_t*)cf + 0x3f0, &hugeHp, 8);  // 0x358+0x98
    memcpy((uint8_t*)cf + 0x3f8, &hugeHp, 8);  // 0x358+0xa0
    // Attribute dump偏移0x368(不减0x10): cur_hp(0xa8) hp(0xb0)
    memcpy((uint8_t*)cf + 0x410, &hugeHp, 8);  // 0x368+0xa8
    memcpy((uint8_t*)cf + 0x418, &hugeHp, 8);  // 0x368+0xb0
}

// 打印CF的hex dump
static void dumpCF(void *cf, int stateType, const char *source) {
    if (!cf || g_isPlayerLogCount >= 10) return;
    g_isPlayerLogCount++;

    uint8_t *p = (uint8_t*)cf;
    int32_t v44=0, v54=0, v64=0, camp24=0, camp34=0;
    memcpy(&v44, p+0x44, 4);
    memcpy(&v54, p+0x54, 4);
    memcpy(&v64, p+0x64, 4);
    memcpy(&camp24, p+0x24, 4);
    memcpy(&camp34, p+0x34, 4);

    // 打印0x00-0x80的hex
    char hex[400];
    int pos = 0;
    for (int i = 0; i < 0x80; i += 16) {
        pos += snprintf(hex+pos, sizeof(hex)-pos, "+%02x:", i);
        for (int j = 0; j < 16; j++) pos += snprintf(hex+pos, sizeof(hex)-pos, "%02x", p[i+j]);
        pos += snprintf(hex+pos, sizeof(hex)-pos, " ");
    }
    jlog(@"CFDump[%d] %s st=%d cf=%p camp24=%d camp34=%d isAI44=%d isAI54=%d isAI64=%d",
         g_isPlayerLogCount, source, stateType, cf, camp24, camp34, v44, v54, v64);
    jlog(@"  %s", hex);
}

static int g_godModeLogCount = 0;

// ============================================================
// Hook implementations
// ============================================================

static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 5) { g_unlockLogCount++; jlog(@"Unlock[%d]: stateType=%d", g_unlockLogCount, a2); }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2);
    return YES;
}

static int g_isReadyLogCount = 0;
static BOOL hookCheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    // v34: GodMode学习也放这里(但IsReady可能不常调用)
    if (g_godMode && characterField) {
        dumpCF(characterField, stateType, "IsReady");
        if (isPlayerCF(characterField) && !g_playerCFLearned) {
            g_playerCF = characterField;
            g_playerCFLearned = YES;
            jlog(@"★ IsReady学到玩家CF=%p", characterField);
        }
        if (g_playerCFLearned && characterField == g_playerCF) {
            makePlayerGodMode(characterField);
        }
    }

    if (g_exSkillNoCD && stateType >= 17) {
        if (g_isReadyLogCount < 30) {
            g_isReadyLogCount++;
            jlog(@"IsReady[%d] stateType=%d → YES", g_isReadyLogCount, stateType);
        }
        return YES;
    }
    if (g_origCheckSkillIsReady) return g_origCheckSkillIsReady(frame, stateType, characterField, states);
    return YES;  // v34: 默认返回YES(v33返回NO导致问题)
}

// v34核心: AttackCanUse被频繁调用, 把学习逻辑放这里
static int g_attackCanUseLogCount = 0;
static BOOL hookCheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    // v34: GodMode学习+设置(不管g_exSkillNoCD)
    if (g_godMode && characterField) {
        // 调试: 打印前10次CF dump
        dumpCF(characterField, stateType, "AttackCanUse");

        // 学习玩家CF
        if (isPlayerCF(characterField)) {
            if (!g_playerCFLearned) {
                g_playerCF = characterField;
                g_playerCFLearned = YES;
                int32_t v44=0, v54=0, v64=0, camp24=0;
                memcpy(&v44, (uint8_t*)characterField+0x44, 4);
                memcpy(&v54, (uint8_t*)characterField+0x54, 4);
                memcpy(&v64, (uint8_t*)characterField+0x64, 4);
                memcpy(&camp24, (uint8_t*)characterField+0x24, 4);
                jlog(@"★ AttackCanUse学到玩家CF=%p camp24=%d isAI44=%d isAI54=%d isAI64=%d",
                     characterField, camp24, v44, v54, v64);
            }
        }

        // 设置玩家无敌+满血
        if (g_playerCFLearned && characterField == g_playerCF) {
            makePlayerGodMode(characterField);
            if (g_godModeLogCount < 10) {
                g_godModeLogCount++;
                jlog(@"GodMode[%d] 设置玩家无敌+满血 cf=%p", g_godModeLogCount, characterField);
            }
        }
    }

    if (g_exSkillNoCD && stateType >= 17) {
        if (g_attackCanUseLogCount < 30) {
            g_attackCanUseLogCount++;
            jlog(@"AttackCanUse[%d] stateType=%d → YES", g_attackCanUseLogCount, stateType);
        }
        return YES;
    }
    if (g_origCheckSkillAttackCanUse) return g_origCheckSkillAttackCanUse(frame, stateType, characterField, states);
    return YES;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

static dispatch_source_t g_godTimer = 0;
static void startGodTimer(void) {
    if (g_godTimer) return;
    g_godTimer = dispatch_source_create(DISPATCH_SOURCE_TYPE_TIMER, 0, 0, dispatch_get_main_queue());
    dispatch_source_set_timer(g_godTimer, dispatch_time(DISPATCH_TIME_NOW, 0), 50 * NSEC_PER_MSEC, 0);
    dispatch_source_set_event_handler(g_godTimer, ^{
        if (g_godMode && g_playerCFLearned && g_playerCF) {
            makePlayerGodMode(g_playerCF);
        }
    });
    dispatch_resume(g_godTimer);
}

// ============================================================
// IL2CPP Runtime Search
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
    jlog(@"=== v34.0 IL2CPP Runtime Search ===");
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
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) { g_funcCheckSkillUnlock=funcAddr; found++; jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) { g_funcLimitDmg=funcAddr; found++; jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcCheckSkillIsReady) { g_funcCheckSkillIsReady=funcAddr; found++; jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCheckSkillAttackCanUse) { g_funcCheckSkillAttackCanUse=funcAddr; found++; jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr); }
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
static UIButton *g_btnExSkillNoCD = nil;
static UIButton *g_btnGodMode = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static void refreshButtons(void) {
    [g_btnIgnoreUnlock setTitle: g_ignoreUnlock ? @"\U00002705 \u5ffd\u7565\u89e3\u9501" : @"\U0000274c \u5ffd\u7565\u89e3\u9501" forState:UIControlStateNormal];
    g_btnIgnoreUnlock.backgroundColor = g_ignoreUnlock ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnExSkillNoCD setTitle: g_exSkillNoCD ? @"\U00002705 \u6280\u80fd\u65e0CD" : @"\U0000274c \u6280\u80fd\u65e0CD" forState:UIControlStateNormal];
    g_btnExSkillNoCD.backgroundColor = g_exSkillNoCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnGodMode setTitle: g_godMode ? @"\U00002705 \u73a9\u5bb6\u4e0d\u6b7b" : @"\U0000274c \u73a9\u5bb6\u4e0d\u6b7b" forState:UIControlStateNormal];
    g_btnGodMode.backgroundColor = g_godMode ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=270;
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
- (void)onExSkillNoCD;
- (void)onGodMode;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onIgnoreUnlock {
    g_ignoreUnlock=!g_ignoreUnlock;
    if (g_ignoreUnlock && !g_skillUnlockHooked) { findIL2CPP(); hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "1.忽略解锁"); }
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "5.IsReady");
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "6.AttackCanUse");
    }
    refreshButtons(); jlog(@"Toggle 技能无CD: %d", g_exSkillNoCD);
}
- (void)onGodMode {
    g_godMode=!g_godMode;
    if (g_godMode) {
        findIL2CPP();
        // v34: AttackCanUse被频繁调用, 是学习玩家CF的最佳位置
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "6.AttackCanUse(GodMode)");
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "5.IsReady(GodMode)");
        startGodTimer();
        jlog(@"GodMode启动: AttackCanUse+IsReady hook + GCD定时器 (v34学习逻辑在AttackCanUse)");
    }
    refreshButtons(); jlog(@"Toggle 玩家不死: %d playerCF=%p learned=%d", g_godMode, g_playerCF, g_playerCFLearned);
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
    CGFloat pw=260, ph=270;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,8,pw,22)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v34.0"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:14]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    CGFloat bx=16, bw=228, bh=32, by0=34, bdy=36;
    g_btnIgnoreUnlock=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnIgnoreUnlock.frame=CGRectMake(bx,by0,bw,bh);
    g_btnIgnoreUnlock.layer.cornerRadius=8; g_btnIgnoreUnlock.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnIgnoreUnlock addTarget:[JYJHActionHandler shared] action:@selector(onIgnoreUnlock) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillNoCD.frame=CGRectMake(bx,by0+bdy,bw,bh);
    g_btnExSkillNoCD.layer.cornerRadius=8; g_btnExSkillNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillNoCD addTarget:[JYJHActionHandler shared] action:@selector(onExSkillNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillNoCD];
    g_btnGodMode=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnGodMode.frame=CGRectMake(bx,by0+bdy*2,bw,bh);
    g_btnGodMode.layer.cornerRadius=8; g_btnGodMode.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnGodMode addTarget:[JYJHActionHandler shared] action:@selector(onGodMode) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnGodMode];
    CGFloat sy = by0 + bdy*3 + 4;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d", g_damageLimit];
    g_sliderLabel.textColor=[UIColor whiteColor]; g_sliderLabel.font=[UIFont systemFontOfSize:12]; [g_panel addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=99999; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    jlog(@"========== JYJH v34.0 (学习逻辑放AttackCanUse) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v34修复: GodMode学习逻辑从IsReady移到AttackCanUse(频繁调用), limitDamage默认100");
    jlog(@"v34vs33: 33的IsReady从未被调用(无CFDump), 34把学习放AttackCanUse");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
