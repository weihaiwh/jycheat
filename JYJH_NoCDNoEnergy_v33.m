/**
 * 剑影江湖 v33.0 - 玩家不死(修复IsAI偏移) + 高伤害秒杀
 *
 * v32问题:
 *   1. isPlayerCF从未匹配(learned=0) → IsAI偏移不对
 *   2. limitDamage默认100太低 → 双方都不掉血
 *   3. 玩家不死实际没生效
 *
 * v32日志分析:
 *   - GodMode hook成功但playerCF=0x0 learned=0
 *   - isPlayerCF读CF+0x54和+0x64 → 都不是IsAI的真实位置
 *   - AttackCanUse stateType=18 = Skill5(正常), 不是防御状态
 *
 * v33修复:
 *   1. IsAI偏移: dump.cs显示0x54, 但IL2CPP struct偏移含0x10虚拟header
 *      → 实际偏移 = 0x54 - 0x10 = 0x44
 *      → 同时读0x44和0x54, 并打印hex dump确认
 *   2. limitDamage默认改为30000(秒杀级)
 *   3. GodMode设置: Invincible=1 + cur_hp=max_hp=99999999
 *   4. CharacterFiled字段实际偏移(dump偏移-0x10):
 *      Invincible: 0x00, Camp: 0x24, IsAI: 0x44
 *      RealAttr: 0x2a0, Attribute: 0x358
 *      RealAttr.cur_hp: 0x2a0+0x88=0x328, RealAttr.hp: 0x2a0+0x90=0x330
 *      Attribute.cur_hp: 0x358+0x98=0x3f0, Attribute.hp: 0x358+0xa0=0x3f8
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
static int g_damageLimit = 30000;  // v33: 默认30000(秒杀级)

// ============================================================
// Type definitions
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*, int, void*, void*);

// ============================================================
// Function pointers & hook state
// ============================================================

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;

// 玩家CharacterFiled指针缓存
static void *g_playerCF = NULL;
static BOOL g_playerCFLearned = NO;

// ============================================================
// 玩家不死核心逻辑
// ============================================================

// v33: IsAI偏移修复
// dump.cs: IsAI at 0x54, 但IL2CPP struct含0x10虚拟header
// 实际偏移 = 0x54 - 0x10 = 0x44
// QBoolean.Value: dump 0x10, 实际 0x00
// 所以IsAI.Value在CF+0x44
static int g_isPlayerLogCount = 0;

static BOOL isPlayerCF(void *cf) {
    if (!cf) return NO;
    // v33: 尝试多个偏移 (0x44=推测正确, 0x54=dump原始, 0x64=之前尝试)
    int32_t isAI_44 = -1, isAI_54 = -1;
    memcpy(&isAI_44, (uint8_t*)cf + 0x44, 4);
    memcpy(&isAI_54, (uint8_t*)cf + 0x54, 4);

    // 玩家: IsAI==0
    if (isAI_44 == 0 || isAI_54 == 0) return YES;
    return NO;
}

// 设置玩家无敌+满血
// v33偏移(dump偏移-0x10):
//   Invincible: 0x10-0x10 = 0x00
//   RealAttr: 0x2b0-0x10 = 0x2a0
//     cur_hp: 0x98-0x10 = 0x88 → CF+0x2a0+0x88 = CF+0x328
//     hp: 0xa0-0x10 = 0x90 → CF+0x2a0+0x90 = CF+0x330
//   Attribute: 0x368-0x10 = 0x358
//     cur_hp: 0xa8-0x10 = 0x98 → CF+0x358+0x98 = CF+0x3f0
//     hp: 0xb0-0x10 = 0xa0 → CF+0x358+0xa0 = CF+0x3f8
static void makePlayerGodMode(void *cf) {
    if (!cf) return;

    // 1. Invincible=1 (CF+0x00)
    uint8_t inv = 1;
    memcpy((uint8_t*)cf + 0x00, &inv, 1);

    // 2. RealAttr满血 (CF+0x328 = cur_hp, CF+0x330 = max_hp)
    int64_t hugeHp = 99999999LL;
    memcpy((uint8_t*)cf + 0x330, &hugeHp, 8);  // max_hp
    memcpy((uint8_t*)cf + 0x328, &hugeHp, 8);  // cur_hp

    // 3. Attribute满血 (CF+0x3f0 = cur_hp, CF+0x3f8 = max_hp)
    memcpy((uint8_t*)cf + 0x3f8, &hugeHp, 8);  // max_hp
    memcpy((uint8_t*)cf + 0x3f0, &hugeHp, 8);  // cur_hp
}

static int g_godModeLogCount = 0;

// 打印CF的hex dump用于调试
static void dumpCF(void *cf, int stateType) {
    if (!cf || g_isPlayerLogCount >= 5) return;
    g_isPlayerLogCount++;

    // 打印CF+0x00到CF+0x80的hex dump
    uint8_t *p = (uint8_t*)cf;
    char hex[256];
    int pos = 0;
    for (int i = 0; i < 0x80; i += 16) {
        pos += snprintf(hex+pos, sizeof(hex)-pos, "%02x%02x%02x%02x ", p[i], p[i+1], p[i+2], p[i+3]);
        pos += snprintf(hex+pos, sizeof(hex)-pos, "%02x%02x%02x%02x ", p[i+4], p[i+5], p[i+6], p[i+7]);
        pos += snprintf(hex+pos, sizeof(hex)-pos, "%02x%02x%02x%02x ", p[i+8], p[i+9], p[i+10], p[i+11]);
        pos += snprintf(hex+pos, sizeof(hex)-pos, "%02x%02x%02x%02x|", p[i+12], p[i+13], p[i+14], p[i+15]);
    }
    int32_t isAI44 = 0, isAI54 = 0, camp24 = 0;
    memcpy(&isAI44, p+0x44, 4);
    memcpy(&isAI54, p+0x54, 4);
    memcpy(&camp24, p+0x24, 4);
    jlog(@"CFDump[%d] st=%d cf=%p camp24=%d isAI44=%d isAI54=%d", g_isPlayerLogCount, stateType, cf, camp24, isAI44, isAI54);
    jlog(@"  %s", hex);
}

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
    // v33: 玩家不死 - 学习玩家CF + 设置无敌
    if (g_godMode && characterField) {
        // 调试: 打印前5次调用的CF hex dump
        dumpCF(characterField, stateType);

        if (isPlayerCF(characterField)) {
            if (!g_playerCFLearned) {
                g_playerCF = characterField;
                g_playerCFLearned = YES;
                int32_t isAI44 = 0, isAI54 = 0, camp24 = 0;
                memcpy(&isAI44, (uint8_t*)characterField + 0x44, 4);
                memcpy(&isAI54, (uint8_t*)characterField + 0x54, 4);
                memcpy(&camp24, (uint8_t*)characterField + 0x24, 4);
                jlog(@"★ 学到玩家CF=%p camp=%d isAI44=%d isAI54=%d", characterField, camp24, isAI44, isAI54);
            }
            makePlayerGodMode(characterField);
            if (g_godModeLogCount < 10) {
                g_godModeLogCount++;
                jlog(@"GodMode[%d] 玩家无敌+满血 cf=%p", g_godModeLogCount, characterField);
            }
        }
    }

    if (g_exSkillNoCD) {
        // Skill4=17, Skill5=18, Skill6=19(大招)
        if (stateType >= 17) {
            if (g_isReadyLogCount < 30) {
                g_isReadyLogCount++;
                jlog(@"IsReady[%d] stateType=%d → YES", g_isReadyLogCount, stateType);
            }
            return YES;
        }
    }
    if (g_origCheckSkillIsReady) return g_origCheckSkillIsReady(frame, stateType, characterField, states);
    return NO;
}

static int g_attackCanUseLogCount = 0;
static BOOL hookCheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    // v33: 玩家不死
    if (g_godMode && characterField && g_playerCFLearned && characterField == g_playerCF) {
        makePlayerGodMode(characterField);
    }

    if (g_exSkillNoCD) {
        if (stateType >= 17) {
            if (g_attackCanUseLogCount < 30) {
                g_attackCanUseLogCount++;
                jlog(@"AttackCanUse[%d] stateType=%d → YES", g_attackCanUseLogCount, stateType);
            }
            return YES;
        }
    }
    if (g_origCheckSkillAttackCanUse) return g_origCheckSkillAttackCanUse(frame, stateType, characterField, states);
    return NO;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

// GCD定时器: 每50ms设置玩家无敌+满血
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
    jlog(@"=== v33.0 IL2CPP Runtime Search ===");
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
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr);
                    g_funcCheckSkillUnlock=funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr);
                    g_funcLimitDmg=funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcCheckSkillIsReady) {
                    jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr);
                    g_funcCheckSkillIsReady=funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCheckSkillAttackCanUse) {
                    jlog(@"FOUND %s.%s params=%u addr=%p", cn?:"?",n,pc,funcAddr);
                    g_funcCheckSkillAttackCanUse=funcAddr; found++;
                }
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"Unlock=%p LimitDmg=%p IsReady=%p AttackCanUse=%p",
         g_funcCheckSkillUnlock, g_funcLimitDmg, g_funcCheckSkillIsReady, g_funcCheckSkillAttackCanUse);
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
    refreshButtons(); jlog(@"Toggle 技能无CD: %d IsReady=%d AttackCanUse=%d", g_exSkillNoCD, g_isReadyHooked, g_attackCanUseHooked);
}
- (void)onGodMode {
    g_godMode=!g_godMode;
    if (g_godMode) {
        findIL2CPP();
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "5.IsReady(GodMode)");
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "6.AttackCanUse(GodMode)");
        startGodTimer();
        jlog(@"GodMode启动: GCD定时器50ms + IsReady/AttackCanUse hook (v33偏移修复)");
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v33.0"; title.textColor=[UIColor cyanColor];
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
    jlog(@"========== JYJH v33.0 (修复IsAI偏移+高伤害) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v33修复: IsAI偏移0x44(dump-0x10), limitDamage默认30000, CF hex dump调试");
    jlog(@"v33vs32: 32的IsAI偏移0x54/0x64不对(learned=0), 33改为0x44");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
