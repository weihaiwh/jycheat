/**
 * 剑影江湖 v12.3 - 精确方法Hook (基于UnityFramework反汇编修正)
 * 
 * v12.0: 所有9个方法都找到了! 但大招仍不能释放
 * v12.1/v12.2: 尝试修正参数签名, 但CalcBufferDamage(10参数)导致cctools编译失败
 * 
 * v12.3策略: 恢复v12.0能编译通过的源码, 做最小改动:
 *   1. 移除SkillModel.CheckSkill (dump.cs中不存在)
 *   2. 移除OnAngerChange hook (UI回调, 非逻辑函数)
 *   3. CalcBufferDamage只搜索不hook (10参数cctools编译失败)
 *   4. 伤害上限通过 get_limitDamage hook 实现 (已验证有效)
 *   5. CheckSkillUnlock/CanUseExSkill/IsExSkillInCD用BoolFunc4 (ARM64 ABI忽略多余参数)
 * 
 * UnityFramework反汇编确认的签名:
 *   CheckSkillUnlock(Frame, CharacterFiled*, CharacterStateType) → 3参数
 *   CanUseExSkill(Int64, Int32, Int32) → 3参数, 无栈帧
 *   IsExSkillInCD(FP, ExSkillData*, ExSkillInfo) → 3参数
 *   CalcBufferDamage: 10参数, 704字节栈帧
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
// 日志系统
// ============================================================

static FILE *g_logFile = NULL;
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
static BOOL g_noAnger = YES;
static int g_damageLimit = 10000;

// Primary hooks
static void *g_funcCanUse = NULL;
static void *g_funcIsReady = NULL;
static void *g_funcLimitDmg = NULL;

typedef BOOL (*BoolFunc4)(void*, int, int, int);
static BoolFunc4 g_origCanUse = NULL;
static BoolFunc4 g_origIsReady = NULL;
typedef int (*IntFunc1)(void*);
static IntFunc1 g_origLimitDmg = NULL;

static BOOL g_cdHooked = NO;
static BOOL g_energyHooked = NO;
static BOOL g_limitHooked = NO;

// v12.3: 精确hook (基于UnityFramework反汇编确认)
// CheckSkillUnlock: 3参数, 用BoolFunc4(ARM64 ABI忽略多余参数)
static void *g_funcCheckSkillUnlock = NULL;
static BoolFunc4 g_origCheckSkillUnlock = NULL;
static BOOL g_skillUnlockHooked = NO;

// CanUseExSkill: 3参数(Int64,Int32,Int32), 用BoolFunc4
static void *g_funcCanUseExSkill = NULL;
static BoolFunc4 g_origCanUseExSkill = NULL;
static BOOL g_canUseExSkillHooked = NO;

// IsExSkillInCD: 3参数, 用BoolFunc4
static void *g_funcIsExSkillInCD = NULL;
static BoolFunc4 g_origIsExSkillInCD = NULL;
static BOOL g_isExSkillInCDHooked = NO;

// CalcBufferDamage: 10参数, 只搜索不hook (cctools交叉编译10参数函数失败)
static void *g_funcCalcBufferDamage = NULL;
static BOOL g_calcBufferDmgHooked = NO;

// UI
static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UIButton *g_btnAnger = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

// ============================================================
// Hook函数
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

static int hookLimitDmg(void *self) {
    return g_damageLimit;
}

/** CheckSkillUnlock(Frame, CharacterFiled*, CharacterStateType) → true (忽略30级解锁) */
static BOOL hookCheckSkillUnlock(void *self, int a1, int a2, int a3) {
    if (g_noAnger) return YES;
    if (g_origCheckSkillUnlock) return g_origCheckSkillUnlock(self, a1, a2, a3);
    return YES;
}

/** CanUseExSkill(Int64, Int32, Int32) → true (大招可用) */
static BOOL hookCanUseExSkill(void *self, int a1, int a2, int a3) {
    if (g_noAnger) return YES;
    if (g_origCanUseExSkill) return g_origCanUseExSkill(self, a1, a2, a3);
    return YES;
}

/** IsExSkillInCD(FP, ExSkillData*, ExSkillInfo) → false (大招不在CD) */
static BOOL hookIsExSkillInCD(void *self, int a1, int a2, int a3) {
    if (g_noAnger) return NO;
    if (g_origIsExSkillInCD) return g_origIsExSkillInCD(self, a1, a2, a3);
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
// 查找IL2CPP方法 (v12: 精确方法名匹配)
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v12.0 IL2CPP Runtime Search (精确匹配) ===");
    
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
                    jlog(@"FOUND %s.CheckSkillAttackCanUse params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcCanUse = funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_funcIsReady) {
                    jlog(@"FOUND %s.CheckSkillIsReady params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcIsReady = funcAddr; found++;
                }
                else if (strcmp(n, "CheckSkillUnlock") == 0 && !g_funcCheckSkillUnlock) {
                    jlog(@"FOUND %s.CheckSkillUnlock params=%u addr=%p ★级别解锁", cn ?: "?", pc, funcAddr);
                    g_funcCheckSkillUnlock = funcAddr; found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_funcLimitDmg) {
                    jlog(@"FOUND %s.get_limitDamage params=%u addr=%p", cn ?: "?", pc, funcAddr);
                    g_funcLimitDmg = funcAddr; found++;
                }
                else if (strcmp(n, "CanUseExSkill") == 0 && !g_funcCanUseExSkill) {
                    jlog(@"FOUND %s.CanUseExSkill params=%u addr=%p ★大招可用", cn ?: "?", pc, funcAddr);
                    g_funcCanUseExSkill = funcAddr; found++;
                }
                else if (strcmp(n, "IsExSkillInCD") == 0 && !g_funcIsExSkillInCD) {
                    jlog(@"FOUND %s.IsExSkillInCD params=%u addr=%p ★大招CD", cn ?: "?", pc, funcAddr);
                    g_funcIsExSkillInCD = funcAddr; found++;
                }
                // CalcBufferDamage: 只搜索记录, 不hook (10参数cctools编译失败)
                else if (strcmp(n, "CalcBufferDamage") == 0 && !g_funcCalcBufferDamage) {
                    jlog(@"FOUND %s.CalcBufferDamage params=%u addr=%p ★伤害(仅搜索)", cn ?: "?", pc, funcAddr);
                    g_funcCalcBufferDamage = funcAddr; found++;
                }
            }
        }
    }
    
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"Primary: CanUse=%p IsReady=%p LimitDmg=%p", g_funcCanUse, g_funcIsReady, g_funcLimitDmg);
    jlog(@"v12.3: CheckSkillUnlock=%p CanUseExSkill=%p IsExSkillInCD=%p CalcBufferDamage=%p(仅搜索)",
         g_funcCheckSkillUnlock, g_funcCanUseExSkill, g_funcIsExSkillInCD, g_funcCalcBufferDamage);
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
    
    // Primary hooks
    if (g_noCD) hookOneFunc(g_funcCanUse, hookCanUse, (void**)&g_origCanUse, &g_cdHooked, "CanUse");
    if (g_noEnergy) hookOneFunc(g_funcIsReady, hookIsReady, (void**)&g_origIsReady, &g_energyHooked, "IsReady");
    hookOneFunc(g_funcLimitDmg, hookLimitDmg, (void**)&g_origLimitDmg, &g_limitHooked, "LimitDmg");
    
    // v12.3: 精确hook (基于UnityFramework反汇编确认)
    if (g_noAnger) {
        hookOneFunc(g_funcCheckSkillUnlock, hookCheckSkillUnlock, (void**)&g_origCheckSkillUnlock, &g_skillUnlockHooked, "CheckSkillUnlock★");
        hookOneFunc(g_funcCanUseExSkill, hookCanUseExSkill, (void**)&g_origCanUseExSkill, &g_canUseExSkillHooked, "CanUseExSkill★");
        hookOneFunc(g_funcIsExSkillInCD, hookIsExSkillInCD, (void**)&g_origIsExSkillInCD, &g_isExSkillInCDHooked, "IsExSkillInCD★");
    }
    
    // CalcBufferDamage: 只搜索记录地址, 不hook (10参数cctools编译失败)
    if (g_funcCalcBufferDamage) {
        jlog(@"CalcBufferDamage found at %p (仅搜索, 不hook)", g_funcCalcBufferDamage);
    }
    
    jlog(@"applyAllHooks done (v12.3 - 反汇编修正)");
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
    jlog(@"Toggle Anger: %d (CheckSkillUnlock+CanUseExSkill+IsExSkillInCD)", g_noAnger);
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
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,440)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v12.3"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:15]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    g_btnCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8; [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnCD];
    g_btnEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8; [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnEnergy];
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
    jlog(@"========== JYJH v12.3 (反汇编修正, CalcBufferDamage仅搜索) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"v12.3: CheckSkillUnlock + CanUseExSkill + IsExSkillInCD + limitDamage");
    
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();
        
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}