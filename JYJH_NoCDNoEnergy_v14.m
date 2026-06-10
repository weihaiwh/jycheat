/**
 * 剑影江湖 v14.0 - 安全hook策略
 *
 * v13.0日志分析结论:
 *   1. CheckSkillUnlock → 返回true: 安全! 不卡死, 普通技能忽略解锁可用且无CD
 *   2. CanUseExSkill → 返回true: 安全! 不卡死
 *   3. IsExSkillInCD → 返回NO+修改数据: 安全! 不卡死
 *   4. CheckSkillAttackCanUse → 任何hook都卡死! (帧同步关键路径)
 *   5. CheckSkillIsReady → 任何hook都卡死! (帧同步关键路径)
 *
 * v14.0策略:
 *   完全不hook CheckSkillAttackCanUse 和 CheckSkillIsReady!
 *   这两个函数是帧同步引擎每帧调用的核心决策函数,
 *   Dobby inline hook的跳转指令(即使hook函数只调原函数)也会导致帧同步超时卡死
 *
 *   只保留4个安全hook:
 *   [1] 忽略解锁: CheckSkillUnlock → true (验证安全, 且间接让普通技能无CD)
 *   [2] 大招可用: CanUseExSkill → true (验证安全)
 *   [3] 大招无CD+怒气: IsExSkillInCD → 修改ExSkillData+返回NO (验证安全)
 *   [4] 伤害上限: get_limitDamage → g_damageLimit (静态属性, 安全)
 *
 *   去掉"无CD"和"无能量"按钮, 因为:
 *   - CheckSkillUnlock返回true已经间接让普通技能忽略等级+无CD(用户确认)
 *   - 普通技能CD/能量无法通过hook实现(帧同步关键路径不可hook)
 *   - 如果帧同步允许, 以后可以尝试定时器方案直接修改内存
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
// 日志 (仅写文件)
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

static BOOL g_ignoreUnlock = NO;   // 忽略解锁 (默认关)
static BOOL g_exSkillAvail = NO;   // 大招可用 (默认关)
static BOOL g_exSkillNoCD = NO;    // 大招无CD+怒气 (默认关)
static int g_damageLimit = 100;    // 伤害上限

// ============================================================
// 数据结构偏移量
// ============================================================

// ExSkillData字段偏移 (值类型无0x10 header, 实际偏移=dump.cs偏移-0x10)
static const int ESD_LV = 0x00;              // lv (Int16) dump.cs=0x10
static const int ESD_ID = 0x04;              // id (Int32) dump.cs=0x14
static const int ESD_DATA = 0x08;            // Data (FP, 8字节) = 怒气值 dump.cs=0x18
static const int ESD_LASTTRIGGERTIME = 0x10; // LastTriggerTime (FP, 8字节) dump.cs=0x20

// ============================================================
// Hook函数指针
// ============================================================

typedef BOOL (*BoolFunc3)(void*, int, int);  // 3参数函数
typedef int  (*IntFunc1)(void*);

static void *g_funcCheckSkillUnlock = NULL; static BoolFunc3 g_origCheckSkillUnlock = NULL; static BOOL g_skillUnlockHooked = NO;
static void *g_funcCanUseExSkill = NULL;    static BoolFunc3 g_origCanUseExSkill = NULL;    static BOOL g_canUseExSkillHooked = NO;
static void *g_funcIsExSkillInCD = NULL;    static BoolFunc3 g_origIsExSkillInCD = NULL;    static BOOL g_isExSkillInCDHooked = NO;
static void *g_funcLimitDmg = NULL;         static IntFunc1 g_origLimitDmg = NULL;          static BOOL g_limitHooked = NO;

// ============================================================
// Hook函数实现
// ============================================================

/**
 * [1] 忽略解锁: CheckSkillUnlock → true
 * 签名: (Frame, CharacterFiled*, CharacterStateType) - 3个参数
 * ARM64: self=x0=Frame*, a1=x1=characterField*, a2=x2=stateType
 *
 * 日志验证: a2=18/19(Skill5/6大招), a2=17(Skill4) → stateType确实在a2
 * 用户确认: 忽略解锁对20级普通技能有效, 能用且无CD
 */
static int g_unlockLogCount = 0;
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2) {
    if (g_ignoreUnlock) {
        if (g_unlockLogCount < 5) {
            g_unlockLogCount++;
            jlog(@"Unlock[%d]: stateType=%d", g_unlockLogCount, a2);
        }
        return YES;
    }
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2);
    return YES;
}

/**
 * [2] 大招可用: CanUseExSkill → true
 * 签名: (Int64 customParam, Int32 usedTimesPack, Int32 exSkillIdx) - 3个参数
 */
static BOOL hookCanUseExSkill(void *self, int a1, int a2) {
    if (g_exSkillAvail) return YES;
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2);
    return YES;
}

/**
 * [3] 大招无CD+无限怒气: IsExSkillInCD
 * 签名: (FP now, ExSkillData* skillp, ExSkillInfo info) - 3个参数
 * ARM64: self=x0=now(FP), a1=x1=ExSkillData*, a2=x2=ExSkillInfo
 *
 * 策略: 修改ExSkillData底层数据 + 返回NO(不在CD)
 *   1. lv = 30 → 等级足够(解决"等级不够"问题)
 *   2. Data = FP极大值 → 怒气满
 *   3. LastTriggerTime = 0 → CD已过
 *
 * 注意: ExSkillData是值类型指针, 偏移需要dump.cs偏移-0x10
 *   但实际偏移需要通过内存dump验证(前5次调用会输出两种方案的解析结果)
 */
static int g_exSkillLogCount = 0;
static BOOL hookIsExSkillInCD(void *self, int a1, int a2) {
    // 无条件日志: 确认此hook是否被调用(不看开关, 每次都记录)
    if (g_exSkillLogCount < 10) {
        g_exSkillLogCount++;
        jlog(@"IsExSkillInCD[%d] called! self=%p a1=%p a2=%p exNoCD=%d",
             g_exSkillLogCount, self, (void*)(uintptr_t)a1, (void*)(uintptr_t)a2, g_exSkillNoCD);
    }

    if (g_exSkillNoCD) {
        void *skillpData = (void*)(uintptr_t)a1;
        if (skillpData) {
            // dump内存(前5次)
            if (g_exSkillLogCount <= 5) {
                uint8_t *p = (uint8_t*)skillpData;
                jlog(@"ExSkillData DUMP ptr=%p:", skillpData);
                jlog(@"  +00: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x",
                     p[0],p[1],p[2],p[3],p[4],p[5],p[6],p[7],
                     p[8],p[9],p[10],p[11],p[12],p[13],p[14],p[15]);
                jlog(@"  +10: %02x %02x %02x %02x %02x %02x %02x %02x  %02x %02x %02x %02x %02x %02x %02x %02x",
                     p[16],p[17],p[18],p[19],p[20],p[21],p[22],p[23],
                     p[24],p[25],p[26],p[27],p[28],p[29],p[30],p[31]);
                // 两种偏移方案解析
                jlog(@"  方案A(无header,-0x10): lv=%d id=%d Data=0x%llx LTT=0x%llx",
                     *(int16_t*)(p+0x00), *(int32_t*)(p+0x04),
                     *(uint64_t*)(p+0x08), *(uint64_t*)(p+0x10));
                jlog(@"  方案B(有header,原偏移): lv=%d id=%d Data=0x%llx LTT=0x%llx",
                     *(int16_t*)(p+0x10), *(int32_t*)(p+0x14),
                     *(uint64_t*)(p+0x18), *(uint64_t*)(p+0x20));
            }

            // 修改ExSkillData (两种偏移方案都写, 确保至少一种命中)
            // 方案A: 无header偏移
            *(int16_t*)((uint8_t*)skillpData + 0x00) = 30;     // lv=30
            *(uint64_t*)((uint8_t*)skillpData + 0x08) = (uint64_t)10000 << 16; // Data=FP(10000)
            *(uint64_t*)((uint8_t*)skillpData + 0x10) = 0;     // LastTriggerTime=0
            // 方案B: 有header偏移(dump.cs原偏移)
            *(int16_t*)((uint8_t*)skillpData + 0x10) = 30;     // lv=30
            *(uint64_t*)((uint8_t*)skillpData + 0x18) = (uint64_t)10000 << 16; // Data=FP(10000)
            *(uint64_t*)((uint8_t*)skillpData + 0x20) = 0;     // LastTriggerTime=0

            jlog(@"ExSkill SET(双方案): A:lv=%d B:lv=%d",
                 *(int16_t*)((uint8_t*)skillpData + 0x00),
                 *(int16_t*)((uint8_t*)skillpData + 0x10));
        }
        return NO; // 不在CD
    }
    if (g_origIsExSkillInCD) return g_origIsExSkillInCD(self, a1, a2);
    return NO;
}

/** [4] 伤害上限: get_limitDamage → g_damageLimit */
static int hookLimitDmg(void *self) {
    return g_damageLimit;
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
    jlog(@"=== v14.0 IL2CPP Runtime Search ===");

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

                // v14.0: 只搜索4个安全函数, 不搜索帧同步关键路径函数
                if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p [1.忽略解锁]", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p [2.大招可用]", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "IsExSkillInCD") == 0 && !g_funcIsExSkillInCD) {
                    jlog(@"FOUND %s.IsExSkillInCD params=%u addr=%p [3.大招无CD]", cn ?: "?", pc, funcAddr);
                    g_funcIsExSkillInCD = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p [4.伤害上限]", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
            }
        }
    }

    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"[1]CheckSkillUnlock=%p [2]CanUseExSkill=%p [3]IsExSkillInCD=%p [4]LimitDmg=%p",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcIsExSkillInCD, g_funcLimitDmg);
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
    if (!g_funcCheckSkillUnlock) findIL2CPP();

    // 只安装伤害上限(默认开启), 其余惰性安装
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "4.伤害上限");

    jlog(@"applyAllHooks done hooked: Unlock=%d ExAvail=%d ExNoCD=%d Limit=%d",
         g_skillUnlockHooked, g_canUseExSkillHooked, g_isExSkillInCDHooked, g_limitHooked);
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

    [g_btnExSkillNoCD setTitle: g_exSkillNoCD ? @"\U00002705 \u5927\u62db\u65e0CD" : @"\U0000274c \u5927\u62cd\u65e0CD" forState:UIControlStateNormal];
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
    if (g_ignoreUnlock && !g_skillUnlockHooked) {
        findIL2CPP();
        hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "1.忽略解锁");
    }
    refreshButtons(); jlog(@"Toggle 忽略解锁: %d hooked=%d", g_ignoreUnlock, g_skillUnlockHooked);
}
- (void)onExSkillAvail {
    g_exSkillAvail=!g_exSkillAvail;
    if (g_exSkillAvail && !g_canUseExSkillHooked) {
        findIL2CPP();
        hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "2.大招可用");
    }
    refreshButtons(); jlog(@"Toggle 大招可用: %d hooked=%d", g_exSkillAvail, g_canUseExSkillHooked);
}
- (void)onExSkillNoCD {
    g_exSkillNoCD=!g_exSkillNoCD;
    if (g_exSkillNoCD && !g_isExSkillInCDHooked) {
        findIL2CPP();
        hookOneFunc(g_funcIsExSkillInCD, hookIsExSkillInCD, (void**)&g_origIsExSkillInCD, &g_isExSkillInCDHooked, "3.大招无CD");
    }
    refreshButtons(); jlog(@"Toggle 大招无CD: %d hooked=%d", g_exSkillNoCD, g_isExSkillInCDHooked);
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v14.0"; title.textColor=[UIColor cyanColor];
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

// ============================================================
// 入口
// ============================================================

__attribute__((constructor))
static void initialize(void) {
    static BOOL loaded = NO;
    if (loaded) { jlog(@"Already loaded, skip"); return; }
    loaded = YES;

    jlog(@"========== JYJH v14.0 (安全hook策略) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"v14.0: 完全不hook帧同步关键路径函数(CheckSkillAttackCanUse/CheckSkillIsReady)");
    jlog(@"  只保留4个安全hook: 忽略解锁/大招可用/大招无CD+怒气/伤害上限");
    jlog(@"  普通技能CD/能量无法通过hook实现(帧同步关键路径不可hook)");

    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();

        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
