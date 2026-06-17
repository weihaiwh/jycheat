/**
 * 剑影江湖 v30.0 - Hook TriggerExSkill + 修改ExSkillData.Data怒气值
 *
 * v22稳定功能：忽略解锁、技能无CD、伤害上限
 * v30新思路：hook ExSkillHelper.TriggerExSkill (不是TryTriggerExSkill!)
 *
 * 关键发现：
 *   TryTriggerExSkill - 外层触发检测，只是判断是否触发
 *   TriggerExSkill - 内层实际执行，接收ExSkillData*指针，能直接改怒气
 *   IsExSkillInCD - CD检查，也在TriggerExSkill内部被调用
 *
 * ExSkillData结构体布局:
 *   +0x10: Int16 lv
 *   +0x14: Int32 id
 *   +0x18: FP Data (怒气值, 8字节RawValue在+0x10偏移, 即ExSkillData+0x28)
 *   +0x20: FP LastTriggerTime
 *   +0x28: UInt64 skills
 *
 * Deterministic.FP结构体:
 *   +0x10: Int64 RawValue (实际定点数值)
 *   FP的RawValue/65536 = 实际值(AsLong)
 *   怒气满值RawValue约131072000(=2000*65536)
 *
 * TriggerExSkill签名:
 *   static Boolean TriggerExSkill(Frame f, ExSkillData* skillp,
 *       EntityRef trigger, EntityRef fuse, List<EntityRef> relationTargets,
 *       FP now, ExSkillInfo info, ExSkillsAsset asset)
 *   地址: 0x30b8e84
 *   参数: (void* f, void* skillp, void* trigger, void* fuse, void* targets, int64_t now_raw, void* info, void* asset)
 *   共8个参数
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
static BOOL g_exSkillRage = NO;  // v30: 大招满怒气
static int g_damageLimit = 100;

// ============================================================
// Type definitions
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);
typedef int  (*IntFunc1)(void*);
typedef BOOL (*BoolFunc8)(void*, uint64_t, void*, void*, void*, void*, void*, uint64_t);
typedef BOOL (*BoolFunc7)(void*, uint64_t, void*, uint64_t, void*, void*, int);
typedef BOOL (*BoolFunc4)(void*, int, void*, void*);

// TriggerExSkill: 8 params
// static Boolean TriggerExSkill(Frame f, ExSkillData* skillp,
//     EntityRef trigger, EntityRef fuse, List<EntityRef> targets,
//     FP now, ExSkillInfo info, ExSkillsAsset asset)
typedef BOOL (*TriggerExSkillFunc)(void*, void*, void*, void*, void*, int64_t, void*, void*);

// ============================================================
// Function pointers & hook state
// ============================================================

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;
static void *g_funcCheckSkillIsReady = NULL; static BoolFunc4 g_origCheckSkillIsReady = NULL; static BOOL g_isReadyHooked = NO;
static void *g_funcCheckSkillAttackCanUse = NULL; static BoolFunc4 g_origCheckSkillAttackCanUse = NULL; static BOOL g_attackCanUseHooked = NO;

// v30: TriggerExSkill (内层执行函数，能改ExSkillData.Data)
static void *g_funcTriggerExSkill = NULL; static TriggerExSkillFunc g_origTriggerExSkill = NULL; static BOOL g_triggerExSkillHooked = NO;

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
    if (g_exSkillNoCD || g_exSkillRage) {
        // Skill6=22(大招), Skill1-5=17-21
        if (stateType == 22 || (g_exSkillNoCD && stateType >= 17)) {
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
    if (g_exSkillNoCD || g_exSkillRage) {
        if (stateType == 22 || (g_exSkillNoCD && stateType >= 17)) {
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

// v30核心: Hook TriggerExSkill, 在执行前将ExSkillData.Data(怒气)填满
//
// ExSkillData结构体:
//   +0x00: [16字节 header/padding]
//   +0x10: Int16 lv
//   +0x14: Int32 id  
//   +0x18: FP Data (怒气值)
//   +0x20: FP LastTriggerTime
//   +0x28: UInt64 skills
//
// FP结构体:
//   +0x00: [16字节 header]
//   +0x10: Int64 RawValue
//
// 所以 ExSkillData.Data.RawValue 在 ExSkillData+0x18+0x10 = ExSkillData+0x28
// 但这不对，因为FP本身有对齐。重新计算：
//   ExSkillData offset 0x18是Data字段
//   Data是FP类型，FP的RawValue在FP+0x10
//   所以Data.RawValue = skillp + 0x18 + 0x10 = skillp + 0x28
//
// 怒气满值: FP的RAW_ONE = 65536 (1.0)
//           RawValue/65536 = 实际值
//           目标怒气2000 → RawValue = 2000 * 65536 = 131072000 = 0x7A120000
//
// 但我们不确定满怒气值是多少，所以策略是：读取当前值，如果<某个阈值就强制填满
// 或者直接填一个很大的值

static int g_triggerExSkillLogCount = 0;
static BOOL hookTriggerExSkill(void *f, void *skillp, void *trigger, void *fuse,
                                void *targets, int64_t now_raw, void *info, void *asset) {
    if (g_exSkillRage && skillp) {
        // 读取ExSkillData字段
        int32_t skillId = 0;
        int64_t oldRageRaw = 0;
        memcpy(&skillId, (uint8_t*)skillp + 0x14, 4);       // id at +0x14
        memcpy(&oldRageRaw, (uint8_t*)skillp + 0x28, 8);     // Data.RawValue at +0x28 (0x18+0x10)

        // 怒气满值: 2000 * 65536 = 131072000
        // 但实际满怒气值可能不同，先用一个大值
        // v22日志显示怒气相关是FP类型，RAW_ONE=65536
        // 设定目标RawValue = 131072000 (≈2000)
        int64_t maxRage = 131072000LL; // 2000 * 65536

        if (oldRageRaw < maxRage) {
            // 填满怒气
            memcpy((uint8_t*)skillp + 0x28, &maxRage, 8);

            // 同时清除CD: LastTriggerTime设为0 (让IsExSkillInCD返回false)
            // LastTriggerTime是FP在+0x20, RawValue在+0x20+0x10=+0x30
            int64_t zeroTime = 0;
            memcpy((uint8_t*)skillp + 0x30, &zeroTime, 8);

            if (g_triggerExSkillLogCount < 20) {
                g_triggerExSkillLogCount++;
                jlog(@"TriggerExSkill[%d] id=%d rage=%lld→%lld CD=0", g_triggerExSkillLogCount, skillId, oldRageRaw, maxRage);
            }
        }
    }

    // 调用原始函数
    if (g_origTriggerExSkill) return g_origTriggerExSkill(f, skillp, trigger, fuse, targets, now_raw, info, asset);
    return NO;
}

static int hookLimitDmg(void *self) { return g_damageLimit; }

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
    jlog(@"=== v30.0 IL2CPP Runtime Search ===");
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
                // v30: TriggerExSkill (不是TryTriggerExSkill!)
                // 区分: ExSkillHelper.TriggerExSkill(8参数) vs TryTriggerExSkill(8参数但不同名)
                else if (strcmp(n, "TriggerExSkill") == 0 && !g_funcTriggerExSkill
                         && cn && strcmp(cn, "ExSkillHelper") == 0) {
                    jlog(@"FOUND %s.%s params=%u addr=%p ★v30核心★", cn,n,pc,funcAddr);
                    g_funcTriggerExSkill=funcAddr; found++;
                }
            }
        }
    }
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"Unlock=%p LimitDmg=%p IsReady=%p AttackCanUse=%p TriggerExSkill=%p",
         g_funcCheckSkillUnlock, g_funcLimitDmg, g_funcCheckSkillIsReady, g_funcCheckSkillAttackCanUse, g_funcTriggerExSkill);
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
static UIButton *g_btnExSkillRage = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static void refreshButtons(void) {
    [g_btnIgnoreUnlock setTitle: g_ignoreUnlock ? @"\U00002705 \u5ffd\u7565\u89e3\u9501" : @"\U0000274c \u5ffd\u7565\u89e3\u9501" forState:UIControlStateNormal];
    g_btnIgnoreUnlock.backgroundColor = g_ignoreUnlock ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnExSkillNoCD setTitle: g_exSkillNoCD ? @"\U00002705 \u6280\u80fd\u65e0CD" : @"\U0000274c \u6280\u80fd\u65e0CD" forState:UIControlStateNormal];
    g_btnExSkillNoCD.backgroundColor = g_exSkillNoCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnExSkillRage setTitle: g_exSkillRage ? @"\U00002705 \u5927\u62db\u6012\u6c14" : @"\U0000274c \u5927\u62db\u6012\u6c14" forState:UIControlStateNormal];
    g_btnExSkillRage.backgroundColor = g_exSkillRage ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
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
- (void)onExSkillRage;
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
- (void)onExSkillRage {
    g_exSkillRage=!g_exSkillRage;
    if (g_exSkillRage) {
        findIL2CPP();
        // 大招怒气需要hook这些：
        // 1. TriggerExSkill - 在帧同步内部修改ExSkillData.Data
        if (!g_triggerExSkillHooked) hookOneFunc(g_funcTriggerExSkill, hookTriggerExSkill, (void**)&g_origTriggerExSkill, &g_triggerExSkillHooked, "7.TriggerExSkill");
        // 2. CheckSkillIsReady - 让UI层允许点击大招按钮
        if (!g_isReadyHooked) hookOneFunc(g_funcCheckSkillIsReady, hookCheckSkillIsReady, (void**)&g_origCheckSkillIsReady, &g_isReadyHooked, "5.IsReady");
        // 3. CheckSkillAttackCanUse - 让攻击检查也通过
        if (!g_attackCanUseHooked) hookOneFunc(g_funcCheckSkillAttackCanUse, hookCheckSkillAttackCanUse, (void**)&g_origCheckSkillAttackCanUse, &g_attackCanUseHooked, "6.AttackCanUse");
    }
    refreshButtons(); jlog(@"Toggle 大招怒气: %d TriggerExSkill=%d IsReady=%d AttackCanUse=%d", g_exSkillRage, g_triggerExSkillHooked, g_isReadyHooked, g_attackCanUseHooked);
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v30.0"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:14]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    CGFloat bx=16, bw=228, bh=32, by0=34, bdy=36;
    g_btnIgnoreUnlock=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnIgnoreUnlock.frame=CGRectMake(bx,by0,bw,bh);
    g_btnIgnoreUnlock.layer.cornerRadius=8; g_btnIgnoreUnlock.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnIgnoreUnlock addTarget:[JYJHActionHandler shared] action:@selector(onIgnoreUnlock) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnIgnoreUnlock];
    g_btnExSkillNoCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillNoCD.frame=CGRectMake(bx,by0+bdy,bw,bh);
    g_btnExSkillNoCD.layer.cornerRadius=8; g_btnExSkillNoCD.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillNoCD addTarget:[JYJHActionHandler shared] action:@selector(onExSkillNoCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillNoCD];
    g_btnExSkillRage=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnExSkillRage.frame=CGRectMake(bx,by0+bdy*2,bw,bh);
    g_btnExSkillRage.layer.cornerRadius=8; g_btnExSkillRage.titleLabel.font=[UIFont boldSystemFontOfSize:13];
    [g_btnExSkillRage addTarget:[JYJHActionHandler shared] action:@selector(onExSkillRage) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnExSkillRage];
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
    jlog(@"========== JYJH v30.0 (Hook TriggerExSkill + 修改怒气) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"v30核心: Hook ExSkillHelper.TriggerExSkill, 执行前填满ExSkillData.Data(怒气)");
    jlog(@"v30vs22: 22只hook外层TryTrigger, 30hook内层TriggerExSkill直接改数据");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done");
        applyAllHooks();
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{ setupUI(); });
    });
}
