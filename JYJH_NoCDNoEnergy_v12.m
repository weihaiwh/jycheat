/**
 * 剑影江湖 v12.5 - 双层Hook(帧同步+UI)
 *
 * v12.4问题:
 *   1. ExSkillData.lastTriggerTime偏移错误: 反汇编0x10, 但dump.cs确认是0x20
 *   2. "需要怒气"是客户端UI限制 — get_IsAnger()让按钮灰显
 *   3. "不能提前解锁"也是客户端UI限制 — get_IsUnlock()
 *   4. 调试日志窗口占空间
 *
 * v12.5策略: 双层Hook
 *   帧同步层(6个): 无CD/无能量/忽略解锁/大招可用/大招无CD/伤害上限
 *   UI层(2个): get_IsUnlock→true, get_IsAnger→false
 *
 * ExSkillData结构(dump.cs确认):
 *   0x10: lv(Int16), 0x14: id(Int32), 0x18: Data(FP), 0x20: LastTriggerTime(FP), 0x28: skills(UInt64)
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

#include "dobby.h"

// ============================================================
// 日志 (仅写文件, 不显示UI)
// ============================================================

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

// ============================================================
// 全局状态
// ============================================================

static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static BOOL g_ignoreUnlock = YES;
static BOOL g_exSkillAvail = YES;
static BOOL g_exSkillNoCD = YES;
static int g_damageLimit = 100;

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc4)(void*, int, int, int);
typedef int  (*IntFunc1)(void*);

static void *g_funcCanUse = NULL;          static BoolFunc4 g_origCanUse = NULL;          static BOOL g_cdHooked = NO;
static void *g_funcIsReady = NULL;         static BoolFunc4 g_origIsReady = NULL;         static BOOL g_energyHooked = NO;
static void *g_funcCheckSkillUnlock = NULL; static BoolFunc4 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;   static BoolFunc4 g_origCanUseExSkill = NULL;   static BOOL g_canUseExSkillHooked = NO;
static void *g_funcIsExSkillInCD = NULL;   static BoolFunc4 g_origIsExSkillInCD = NULL;   static BOOL g_isExSkillInCDHooked = NO;
static void *g_funcLimitDmg = NULL;        static IntFunc1 g_origLimitDmg = NULL;         static BOOL g_limitHooked = NO;
static void *g_funcGetIsUnlock = NULL;     static BoolFunc4 g_origGetIsUnlock = NULL;     static BOOL g_isUnlockHooked = NO;
static void *g_funcGetIsAnger = NULL;      static BoolFunc4 g_origGetIsAnger = NULL;      static BOOL g_isAngerHooked = NO;
static void *g_funcCalcBufferDamage = NULL;

// ============================================================
// Hook函数实现
// ============================================================

static BOOL hookCanUse(void *self, int a1, int a2, int a3) {
    if (g_noCD) return YES;
    if (g_origCanUse) return g_origCanUse(self, a1, a2, a3);
    return YES;
}

static BOOL hookIsReady(void *self, int a1, int a2, int a3) {
    if (g_noEnergy) return YES;
    if (g_origIsReady) return g_origIsReady(self, a1, a2, a3);
    return YES;
}

static BOOL hookCheckSkillUnlock(void *self, int a1, int a2, int a3) {
    if (g_ignoreUnlock) return YES;
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2, a3);
    return YES;
}

static BOOL hookCanUseExSkill(void *self, int a1, int a2, int a3) {
    if (g_exSkillAvail) return YES;
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2, a3);
    return YES;
}

/**
 * 大招无CD: IsExSkillInCD → false + 清除LastTriggerTime@0x20
 * dump.cs: ExSkillData.lv=0x10, id=0x14, Data=0x18, LastTriggerTime=0x20, skills=0x28
 * IsExSkillInCD(FP now, ExSkillData* skillp, ExSkillInfo info)
 * ARM64: x0=now, x1=skillp, x2=info → BoolFunc4: self=x0, a1=x1=ExSkillData*
 */
static BOOL hookIsExSkillInCD(void *self, int a1, int a2, int a3) {
    if (g_exSkillNoCD) {
        void *skillpData = (void*)(uintptr_t)a1;
        if (skillpData) {
            // LastTriggerTime在offset 0x20 (dump.cs确认!), FP=8字节
            uint64_t *ltt = (uint64_t*)((uint8_t*)skillpData + 0x20);
            *ltt = 0;
        }
        return NO;
    }
    if (g_origIsExSkillInCD) return g_origIsExSkillInCD(self, a1, a2, a3);
    return NO;
}

static int hookLimitDmg(void *self) {
    return g_damageLimit;
}

/** UI: get_IsUnlock → true (技能按钮不灰显) */
static BOOL hookGetIsUnlock(void *self, int a1, int a2, int a3) {
    if (g_ignoreUnlock) return YES;
    if (g_origGetIsUnlock) return g_origGetIsUnlock(self, a1, a2, a3);
    return YES;
}

/** UI: get_IsAnger → false (怒气已满, 大招按钮可用) */
static BOOL hookGetIsAnger(void *self, int a1, int a2, int a3) {
    if (g_exSkillNoCD) return NO;
    if (g_origGetIsAnger) return g_origGetIsAnger(self, a1, a2, a3);
    return NO;
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

// ============================================================
// 查找IL2CPP方法
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v12.5 IL2CPP Runtime Search ===");

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

    int found = 0;
    int totalMethods = 0;

    for (size_t a = 0; a < assemCount; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;

        for (size_t c = 0; c < cnt; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            const char *cn = class_name_func ? class_name_func(klass) : NULL;

            void *iter = NULL;
            void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;

                uint32_t pc = param_count ? param_count(m) : 0;
                void *funcAddr = NULL;
                memcpy(&funcAddr, m, sizeof(void*));

                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_funcCanUse) {
                    jlog(@"FOUND %s.CheckSkillAttackCanUse params=%u addr=%p [1.无CD]", cn ?: "?", pc, funcAddr);
                    g_funcCanUse = funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcIsReady) {
                    jlog(@"FOUND %s.CheckSkillIsReady params=%u addr=%p [2.无能量]", cn ?: "?", pc, funcAddr);
                    g_funcIsReady = funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p [3.忽略解锁]", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p [4.大招可用]", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "IsExSkillInCD") == 0 && !g_funcIsExSkillInCD) {
                    jlog(@"FOUND %s.IsExSkillInCD params=%u addr=%p [5.大招无CD]", cn ?: "?", pc, funcAddr);
                    g_funcIsExSkillInCD = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p [6.伤害上限]", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
                else if (strcmp(n, "get_IsUnlock") == 0 && cn && strcmp(cn, "UIC_FHSkillItem") == 0 && !g_funcGetIsUnlock) {
                    jlog(@"FOUND %s.get_IsUnlock params=%u addr=%p [UI-解锁]", cn ?: "?", pc, funcAddr);
                    g_funcGetIsUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "get_IsAnger") == 0 && cn && strcmp(cn, "UIC_FHSkillItem") == 0 && !g_funcGetIsAnger) {
                    jlog(@"FOUND %s.get_IsAnger params=%u addr=%p [UI-怒气]", cn ?: "?", pc, funcAddr);
                    g_funcGetIsAnger = funcAddr; found++;
                }
                else if (strcmp(n, "CalcBufferDamage") == 0 && !g_funcCalcBufferDamage) {
                    jlog(@"FOUND %s.CalcBufferDamage params=%u addr=%p (仅搜索)", cn ?: "?", pc, funcAddr);
                    g_funcCalcBufferDamage = funcAddr; found++;
                }
            }
        }
    }

    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"[1]CanUse=%p [2]IsReady=%p [3]CheckSkillUnlock=%p", g_funcCanUse, g_funcIsReady, g_funcCheckSkillUnlock);
    jlog(@"[4]CanUseExSkill=%p [5]IsExSkillInCD=%p [6]LimitDmg=%p", g_funcCanUseExSkill, g_funcIsExSkillInCD, g_funcLimitDmg);
    jlog(@"[UI]get_IsUnlock=%p get_IsAnger=%p", g_funcGetIsUnlock, g_funcGetIsAnger);
}

// ============================================================
// Dobby Hook 操作
// ============================================================

static void hookOneFunc(void *funcAddr, void *hookFunc, void **origFunc, BOOL *hookedFlag, const char *name) {
    if (!funcAddr) { jlog(@"%s: funcAddr not found, skip", name); return; }
    if (*hookedFlag) { jlog(@"%s: already hooked", name); return; }
    int ret = DobbyHook(funcAddr, hookFunc, origFunc);
    if (ret == 0) {
        *hookedFlag = YES;
        jlog(@"%s: DobbyHook OK at %p, orig=%p", name, funcAddr, *origFunc);
    } else {
        jlog(@"%s: DobbyHook FAILED ret=%d addr=%p", name, ret, funcAddr);
    }
}

static void applyAllHooks(void) {
    if (!g_funcCanUse) findIL2CPP();

    // 帧同步层
    if (g_noCD) hookOneFunc(g_funcCanUse, hookCanUse, (void**)&g_origCanUse, &g_cdHooked, "1.无CD");
    if (g_noEnergy) hookOneFunc(g_funcIsReady, hookIsReady, (void**)&g_origIsReady, &g_energyHooked, "2.无能量");
    if (g_ignoreUnlock) hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "3.忽略解锁");
    if (g_exSkillAvail) hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "4.大招可用");
    if (g_exSkillNoCD) hookOneFunc(g_funcIsExSkillInCD, hookIsExSkillInCD, (void**)&g_origIsExSkillInCD, &g_isExSkillInCDHooked, "5.大招无CD");
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "6.伤害上限");

    // UI层
    if (g_ignoreUnlock) hookOneFunc(g_funcGetIsUnlock, hookGetIsUnlock, (void**)&g_origGetIsUnlock, &g_isUnlockHooked, "UI-解锁");
    if (g_exSkillNoCD) hookOneFunc(g_funcGetIsAnger, hookGetIsAnger, (void**)&g_origGetIsAnger, &g_isAngerHooked, "UI-怒气");

    jlog(@"applyAllHooks done (v12.5 - 双层Hook + LastTriggerTime@0x20修复)");
}

// ============================================================
// UI
// ============================================================

static UIView *g_panel = nil;
static UIButton *g_btnNoCD = nil;
static UIButton *g_btnNoEnergy = nil;
static UIButton *g_btnIgnoreUnlock = nil;
static UIButton *g_btnExSkillAvail = nil;
static UIButton *g_btnExSkillNoCD = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static void refreshButtons(void) {
    [g_btnNoCD setTitle: g_noCD ? @"\U00002705 \u65e0CD" : @"\U0000274c \u65e0CD" forState:UIControlStateNormal];
    g_btnNoCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnNoEnergy setTitle: g_noEnergy ? @"\U00002705 \u65e0\u80fd\u91cf" : @"\U0000274c \u65e0\u80fd\u91cf" forState:UIControlStateNormal];
    g_btnNoEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnIgnoreUnlock setTitle: g_ignoreUnlock ? @"\U00002705 \u5ffd\u7565\u89e3\u9501" : @"\U0000274c \u5ffd\u7565\u89e3\u9501" forState:UIControlStateNormal];
    g_btnIgnoreUnlock.backgroundColor = g_ignoreUnlock ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnExSkillAvail setTitle: g_exSkillAvail ? @"\U00002705 \u5927\u62db\u53ef\u7528" : @"\U0000274c \u5927\u62db\u53ef\u7528" forState:UIControlStateNormal];
    g_btnExSkillAvail.backgroundColor = g_exSkillAvail ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];

    [g_btnExSkillNoCD setTitle: g_exSkillNoCD ? @"\U00002705 \u5927\u62db\u65e0CD" : @"\U0000274c \u5927\u62db\u65e0CD" forState:UIControlStateNormal];
    g_btnExSkillNoCD.backgroundColor = g_exSkillNoCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=310;
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
- (void)onNoCD;
- (void)onNoEnergy;
- (void)onIgnoreUnlock;
- (void)onExSkillAvail;
- (void)onExSkillNoCD;
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onNoCD { g_noCD=!g_noCD; refreshButtons(); jlog(@"Toggle 无CD: %d", g_noCD); }
- (void)onNoEnergy { g_noEnergy=!g_noEnergy; refreshButtons(); jlog(@"Toggle 无能量: %d", g_noEnergy); }
- (void)onIgnoreUnlock { g_ignoreUnlock=!g_ignoreUnlock; refreshButtons(); jlog(@"Toggle 忽略解锁: %d", g_ignoreUnlock); }
- (void)onExSkillAvail { g_exSkillAvail=!g_exSkillAvail; refreshButtons(); jlog(@"Toggle 大招可用: %d", g_exSkillAvail); }
- (void)onExSkillNoCD { g_exSkillNoCD=!g_exSkillNoCD; refreshButtons(); jlog(@"Toggle 大招无CD: %d", g_exSkillNoCD); }
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
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];

    CGFloat pw=260, ph=310;
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,pw,ph)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];

    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,8,pw,22)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v12.5"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:14]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];

    CGFloat bx=16, bw=228, bh=32, by0=34, bdy=36;
    g_btnNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnNoCD.frame=CGRectMake(bx,by0,bw,bh);
    g_btnNoCD.layer.cornerRadius=8; g_btnNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnNoCD addTarget:[JYJHActionHandler shared] action:@selector(onNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnNoCD];

    g_btnNoEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnNoEnergy.frame=CGRectMake(bx,by0+bdy,bw,bh);
    g_btnNoEnergy.layer.cornerRadius=8; g_btnNoEnergy.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnNoEnergy addTarget:[JYJHActionHandler shared] action:@selector(onNoEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnNoEnergy];

    g_btnIgnoreUnlock=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnIgnoreUnlock.frame=CGRectMake(bx,by0+bdy*2,bw,bh);
    g_btnIgnoreUnlock.layer.cornerRadius=8; g_btnIgnoreUnlock.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnIgnoreUnlock addTarget:[JYJHActionHandler shared] action:@selector(onIgnoreUnlock) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnIgnoreUnlock];

    g_btnExSkillAvail=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillAvail.frame=CGRectMake(bx,by0+bdy*3,bw,bh);
    g_btnExSkillAvail.layer.cornerRadius=8; g_btnExSkillAvail.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillAvail addTarget:[JYJHActionHandler shared] action:@selector(onExSkillAvail) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillAvail];

    g_btnExSkillNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillNoCD.frame=CGRectMake(bx,by0+bdy*4,bw,bh);
    g_btnExSkillNoCD.layer.cornerRadius=8; g_btnExSkillNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillNoCD addTarget:[JYJHActionHandler shared] action:@selector(onExSkillNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillNoCD];

    CGFloat sy = by0 + bdy*5 + 4;
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(bx,sy,bw,18)];
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d", g_damageLimit];
    g_sliderLabel.textColor=[UIColor whiteColor]; g_sliderLabel.font=[UIFont systemFontOfSize:12]; [g_panel addSubview:g_sliderLabel];

    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(bx,sy+20,bw,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=30000; g_slider.value=g_damageLimit;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];

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

    jlog(@"========== JYJH v12.5 (双层Hook + LastTriggerTime@0x20修复) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
