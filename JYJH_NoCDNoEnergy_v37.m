/**
 * 剑影江湖 v37.0 - Hook CanBeAttack/Damage 实现不死+高伤
 *
 * v36问题:
 *   1. Invincible=1写入帧同步内存 → 帧同步回滚/检测不一致 → 退图卡住
 *   2. 修改normalBoundExtents(玩家自身碰撞箱) → 不影响技能命中范围 → 全屏无效
 *
 * v37新方案:
 *   1. 玩家不死: Hook CanBeAttack(cf) → 玩家返回NO(不可被攻击)
 *      不修改帧同步内存, 不被回滚, 不被检测
 *   2. 高伤害: Hook Damage() → 当目标是玩家时返回0(免伤)
 *   3. 伤害上限: get_limitDamage返回高值(30000)
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
static BOOL g_exSkillNoCD = NO;
static BOOL g_godMode = NO;
static int g_damageLimit = 30000;

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc4)(void*, int, void*, void*);
typedef BOOL (*CanBeAttackFunc)(void*);
typedef int64_t (*DamageFunc)(void*, void*, void*, void*, void*, int32_t, int32_t, BOOL, int32_t, int32_t, void*, void*);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;
static void *g_funcCanBeAttack = NULL;      static CanBeAttackFunc g_origCanBeAttack = NULL; static BOOL g_canBeAttackHooked = NO;
static void *g_funcDamage = NULL;           static DamageFunc g_origDamage = NULL;           static BOOL g_damageHooked = NO;

static void *g_playerCF = NULL;
static BOOL g_playerCFLearned = NO;
static int g_isPlayerLogCount = 0;

static BOOL isPlayerCF(void *cf) {
    if (!cf) return NO;
    int32_t isAI = -1;
    memcpy(&isAI, (uint8_t*)cf + 0x44, 4);
    return (isAI == 0);
}

static void dumpCF(void *cf, int stateType, const char *source) {
    if (!cf || g_isPlayerLogCount >= 15) return;
    g_isPlayerLogCount++;
    uint8_t *p = (uint8_t*)cf;
    int32_t isAI44=0, camp24=0;
    memcpy(&isAI44, p+0x44, 4);
    memcpy(&camp24, p+0x24, 4);
    char hex[400]; int pos = 0;
    for (int i = 0; i < 0x80; i += 16) {
        pos += snprintf(hex+pos, sizeof(hex)-pos, "+%02x:", i);
        for (int j = 0; j < 16; j++) pos += snprintf(hex+pos, sizeof(hex)-pos, "%02x", p[i+j]);
        pos += snprintf(hex+pos, sizeof(hex)-pos, " ");
    }
    jlog(@"CFDump[%d] %s st=%d cf=%p camp=%d isAI=%d %s", g_isPlayerLogCount, source, stateType, cf, camp24, isAI44, isAI44==0 ? "★玩家!" : "(怪)");
    jlog(@"  %s", hex);
}

static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 5) { g_unlockLogCount++; jlog(@"Unlock[%d]: st=%d", g_unlockLogCount, a2); }
        return YES;
    }
    return g_origCheckSkillUnlock ? g_origCheckSkillUnlock(self, a1, a2) : YES;
}

static int g_isReadyLogCount = 0;
static int g_godModeLogCount = 0;
static BOOL hookCheckSkillIsReady(void *frame, int stateType, void *characterField, void *states) {
    if (g_godMode && characterField) {
        dumpCF(characterField, stateType, "IsReady");
        if (isPlayerCF(characterField) && !g_playerCFLearned) {
            g_playerCF = characterField; g_playerCFLearned = YES;
            jlog(@"★★★ IsReady学到玩家CF=%p ★★★", characterField);
        }
    }
    if (g_exSkillNoCD && stateType >= 17) {
        if (g_isReadyLogCount < 30) { g_isReadyLogCount++; jlog(@"IsReady[%d] st=%d→YES", g_isReadyLogCount, stateType); }
        return YES;
    }
    return g_origCheckSkillIsReady ? g_origCheckSkillIsReady(frame, stateType, characterField, states) : YES;
}

static int g_attackCanUseLogCount = 0;
static BOOL hookCheckSkillAttackCanUse(void *frame, int stateType, void *characterField, void *states) {
    if (g_godMode && characterField) {
        dumpCF(characterField, stateType, "AttackCanUse");
        if (isPlayerCF(characterField) && !g_playerCFLearned) {
            g_playerCF = characterField; g_playerCFLearned = YES;
            jlog(@"★★★ AttackCanUse学到玩家CF=%p ★★★", characterField);
        }
    }
    if (g_exSkillNoCD && stateType >= 17) {
        if (g_attackCanUseLogCount < 30) { g_attackCanUseLogCount++; jlog(@"AttackCanUse[%d] st=%d→YES", g_attackCanUseLogCount, stateType); }
        return YES;
    }
    return g_origCheckSkillAttackCanUse ? g_origCheckSkillAttackCanUse(frame, stateType, characterField, states) : YES;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

// v37核心: Hook CanBeAttack - 玩家不可被攻击
static int g_canBeAttackLogCount = 0;
static BOOL hookCanBeAttack(void *cf) {
    if (g_godMode && cf && isPlayerCF(cf)) {
        if (g_canBeAttackLogCount < 20) { g_canBeAttackLogCount++; jlog(@"CanBeAttack[%d]: 玩家→NO", g_canBeAttackLogCount); }
        return NO;
    }
    return g_origCanBeAttack ? g_origCanBeAttack(cf) : YES;
}

// v37核心: Hook Damage - 玩家受伤=0
static int g_damageLogCount = 0;
static int64_t hookDamage(void *f, void *atkEntity, void *atkCF, void *tgtEntity, void *tgtCF,
                          int32_t hitEffectId, int32_t hitSound, BOOL isRight,
                          int32_t skillButton, int32_t skillPart, void *hurtFlag, void *exSkills) {
    BOOL tgtIsPlayer = (tgtCF && isPlayerCF(tgtCF));
    BOOL atkIsPlayer = (atkCF && isPlayerCF(atkCF));

    if (g_godMode && tgtIsPlayer) {
        if (g_damageLogCount < 20) { g_damageLogCount++; jlog(@"Damage[%d]: 目标=玩家 → 返回0(免伤)", g_damageLogCount); }
        return 0;
    }

    if (!g_origDamage) return 0;
    int64_t result = g_origDamage(f, atkEntity, atkCF, tgtEntity, tgtCF, hitEffectId, hitSound, isRight, skillButton, skillPart, hurtFlag, exSkills);

    if (atkIsPlayer && result > 0) {
        if (g_damageLogCount < 20) { g_damageLogCount++; jlog(@"Damage[%d]: 攻击者=玩家 原伤=%lld", g_damageLogCount, result); }
    }
    return result;
}

// IL2CPP search
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
    jlog(@"=== v37.0 IL2CPP Runtime Search ===");
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
    void *domain = domain_get(); if (!domain) return;
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
                else if (strcmp(n, "CanBeAttack") == 0 && !g_funcCanBeAttack) { g_funcCanBeAttack=funcAddr; found++; jlog(@"FOUND %s.%s params=%u addr=%p ★v37★", cn?:"?",n,pc,funcAddr); }
                else if (strcmp(n, "Damage") == 0 && pc >= 10 && !g_funcDamage) { g_funcDamage=funcAddr; found++; jlog(@"FOUND %s.%s params=%u addr=%p ★v37★", cn?:"?",n,pc,funcAddr); }
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
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "伤害上限");
    jlog(@"applyAllHooks done");
}

// UI
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
    CGFloat pw=260, ph=250;
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
    if (g_ignoreUnlock && !g_skillUnlockHooked) { findIL2CPP(); hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "忽略解锁"); }
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD) {
        findIL2CPP();
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "IsReady");
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "AttackCanUse");
    }
    refreshButtons(); jlog(@"Toggle 技能无CD: %d", g_exSkillNoCD);
}
- (void)onGodMode {
    g_godMode=!g_godMode;
    if (g_godMode) {
        findIL2CPP();
        // Hook AttackCanUse学习玩家CF
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "AttackCanUse(God)");
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "IsReady(God)");
        // v37核心: Hook CanBeAttack + Damage
        if (!g_canBeAttackHooked) hookOneFunc(g_funcCanBeAttack, hookCanBeAttack, (void**)&g_origCanBeAttack, &g_canBeAttackHooked, "CanBeAttack★");
        if (!g_damageHooked) hookOneFunc(g_funcDamage, hookDamage, (void**)&g_origDamage, &g_damageHooked, "Damage★");
        jlog(@"GodMode启动: Hook CanBeAttack+Damage(不修改帧同步内存)");
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
    CGFloat pw=260, ph=250;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,8,pw,22)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v37.0"; title.textColor=[UIColor cyanColor];
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
    g_slider.minimumValue=1; g_slider.maximumValue=99999; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    refreshButtons();
}

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) return;
    loaded = YES;
    jlog(@"========== JYJH v37.0 (Hook CanBeAttack+Damage) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v37: 玩家不死=Hook CanBeAttack返回NO(不修改帧同步内存)");
    jlog(@"v37: 免伤=Hook Damage目标为玩家时返回0");
    jlog(@"v37: 伤害上限默认30000");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
