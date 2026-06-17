/**
 * 剑影江湖 v32.0 - 玩家不死(Invincible+满血) + 技能无CD + 伤害上限
 *
 * v31失败: DecreaseHP hook导致游戏卡住(虽然blocked=0,函数从未被调用)
 * v32新方向: 不hook伤害函数, 改为设置玩家Invincible标志+满血
 *
 * 核心思路:
 *   CharacterFiled有Invincible字段(Byte, +0x10) → 设置为1
 *   CharacterFiled.RealAttr(+0x2b0) → RealAttribute.cur_hp(+0x98) = max_hp(+0xa0)
 *   通过CheckSkillIsReady每帧被调用时, 设置玩家无敌+满血
 *   不hook伤害函数 → 不会破坏帧同步 → 不会卡住
 *
 * CharacterFiled关键字段:
 *   +0x10: Byte Invincible (无敌标志)
 *   +0x34: Int32 Camp
 *   +0x54: QBoolean IsAI (玩家=0, 怪物≠0)
 *   +0x2b0: RealAttribute RealAttr
 *     +0x98: Int64 cur_hp
 *     +0xa0: Int64 hp (max_hp)
 *   +0x368: CharacterAttribute Attribute
 *     +0xa8: Int64 cur_hp
 *     +0xb0: Int64 hp (max_hp)
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
static BOOL g_godMode = NO;       // v32: 玩家不死
static int g_damageLimit = 100;

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

// 判断CharacterFiled是否是玩家(IsAI==0)
// 同时尝试+0x54和+0x64两个位置(QBoolean.Value偏移不确定)
static BOOL isPlayerCF(void *cf) {
    if (!cf) return NO;
    int32_t isAI_54 = -1, isAI_64 = -1;
    memcpy(&isAI_54, (uint8_t*)cf + 0x54, 4);
    memcpy(&isAI_64, (uint8_t*)cf + 0x64, 4);
    // 玩家: IsAI==0
    if (isAI_54 == 0 || isAI_64 == 0) return YES;
    return NO;
}

// 设置玩家无敌+满血
static void makePlayerGodMode(void *cf) {
    if (!cf) return;

    // 1. 设置Invincible=1 (CF+0x10)
    uint8_t inv = 1;
    memcpy((uint8_t*)cf + 0x10, &inv, 1);

    // 2. 设置满血 (RealAttr)
    // RealAttr at CF+0x2b0
    // cur_hp at RealAttr+0x98 → CF+0x348
    // hp(max) at RealAttr+0xa0 → CF+0x350
    int64_t maxHp = 0;
    memcpy(&maxHp, (uint8_t*)cf + 0x350, 8);
    if (maxHp > 0) {
        int64_t curHp = 0;
        memcpy(&curHp, (uint8_t*)cf + 0x348, 8);
        if (curHp < maxHp) {
            memcpy((uint8_t*)cf + 0x348, &maxHp, 8);
        }
        // 同时加大max_hp确保打不死
        int64_t hugeHp = 99999999LL;
        memcpy((uint8_t*)cf + 0x350, &hugeHp, 8);
        memcpy((uint8_t*)cf + 0x348, &hugeHp, 8);
    }

    // 3. 也设置Attribute的HP (CF+0x368)
    // cur_hp at Attribute+0xa8 → CF+0x410
    // hp(max) at Attribute+0xb0 → CF+0x418
    int64_t hugeHp2 = 99999999LL;
    memcpy((uint8_t*)cf + 0x418, &hugeHp2, 8);
    memcpy((uint8_t*)cf + 0x410, &hugeHp2, 8);
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
    // v32: 玩家不死 - 在每帧调用中设置玩家无敌+满血
    if (g_godMode && characterField) {
        if (isPlayerCF(characterField)) {
            // 学习玩家CF指针
            if (!g_playerCFLearned) {
                g_playerCF = characterField;
                g_playerCFLearned = YES;
                int32_t camp = 0, isAI54 = 0, isAI64 = 0;
                memcpy(&camp, (uint8_t*)characterField + 0x34, 4);
                memcpy(&isAI54, (uint8_t*)characterField + 0x54, 4);
                memcpy(&isAI64, (uint8_t*)characterField + 0x64, 4);
                jlog(@"★ 学到玩家CF=%p camp=%d isAI54=%d isAI64=%d", characterField, camp, isAI54, isAI64);
            }
            makePlayerGodMode(characterField);
            if (g_godModeLogCount < 10) {
                g_godModeLogCount++;
                jlog(@"GodMode[%d] 玩家无敌+满血 cf=%p", g_godModeLogCount, characterField);
            }
        }
    }

    if (g_exSkillNoCD) {
        if (stateType >= 17) {
            if (g_isReadyLogCount < 30) {
                g_isReadyLogCount++;
                jlog(@"IsReady[%d] stateType=%d → YES", g_isReadyLogCount, stateType);
            }
            return YES;
        }
    }
    if (g_origCheckSkillIsReady) return g_origCheckSkillIsReady(frame, stateType, characterField, states);
    return YES;
}

static int g_attackCanUseLogCount = 0;
static BOOL hookCheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    // v32: 玩家不死 - 也在这里设置
    if (g_godMode && characterField && isPlayerCF(characterField)) {
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
    return YES;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

// GCD定时器: 每50ms设置玩家无敌+满血(补充帧同步回滚)
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
    jlog(@"=== v32.0 IL2CPP Runtime Search ===");
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
        // 玩家不死需要hook CheckSkillIsReady(每帧调用, 用于学习玩家CF+设置无敌)
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "5.IsReady(GodMode)");
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "6.AttackCanUse(GodMode)");
        startGodTimer();
        jlog(@"GodMode启动: GCD定时器50ms + IsReady/AttackCanUse hook");
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v32.0"; title.textColor=[UIColor cyanColor];
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
    g_slider.minimumValue=100; g_slider.maximumValue=30000; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    jlog(@"========== JYJH v32.0 (玩家不死 Invincible+满血) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v32核心: 不hook伤害函数, 通过设置Invincible=1+满血实现玩家不死");
    jlog(@"v32vs31: 31 hook DecreaseHP导致卡住, 32改为设置CF字段");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
