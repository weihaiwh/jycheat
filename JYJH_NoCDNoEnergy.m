/**
 * 剑影江湖 v10.0 - 使用Dobby框架做inline hook (和libtool一样!)
 * 
 * v9.2的问题: 直接vm_protect+memcpy修改代码页 → 进入战斗闪退
 *   原因: iOS 15上vm_protect(RWX)可能不能真正修改代码页
 *         没有指令重定位, 破坏函数prologue可能引发问题
 *         不是线程安全的
 *
 * v10.0的方案: 使用Dobby框架做inline hook (和libtool一样!)
 *   libtool内部用的就是Dobby! (DobbyHook, dobby_set_near_trampoline)
 *   Dobby正确处理了:
 *     - vm_protect代码页权限修改
 *     - ARM64指令重定位(relocate)到trampoline
 *     - 多线程安全(暂停其他线程)
 *     - CPU缓存刷新(sys_icache_invalidate)
 *     - 代码签名绕过
 *
 *   用法:
 *     DobbyHook(target_func, replace_func, &orig_func)
 *     → target_func开头被替换为跳转到replace_func
 *     → orig_func指向trampoline, 调用orig_func等于调用原函数
 *     → DobbyDestroyHook(target_func) 恢复原始函数
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

// Dobby框架头文件
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
static int g_damageLimit = 10000;

// IL2CPP MethodInfo指针
static void *g_infoCanUse = NULL;
static void *g_infoIsReady = NULL;
static void *g_infoLimitDmg = NULL;

// 原始函数地址 (从MethodInfo.methodPointer读出)
static void *g_funcCanUse = NULL;
static void *g_funcIsReady = NULL;
static void *g_funcLimitDmg = NULL;

// Dobby hook后的原始函数指针 (调用trampoline)
// CheckSkillAttackCanUse: 原始签名 bool(CharacterFiled*, int, int, int)
typedef BOOL (*CanUseFuncType)(void *self, int a1, int a2, int a3);
static CanUseFuncType g_origCanUse = NULL;

// CheckSkillIsReady: 原始签名 bool(CharacterFiled*, int, int, int)
typedef BOOL (*IsReadyFuncType)(void *self, int a1, int a2, int a3);
static IsReadyFuncType g_origIsReady = NULL;

// get_limitDamage: 原始签名 int(RuntimeConfig*)
typedef int (*LimitDmgFuncType)(void *self);
static LimitDmgFuncType g_origLimitDmg = NULL;

// Hook状态
static BOOL g_cdHooked = NO;
static BOOL g_energyHooked = NO;
static BOOL g_limitHooked = NO;

// UI
static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

// ============================================================
// 替代函数 (Dobby hook的目标函数)
// ============================================================

/**
 * 替代 CheckSkillAttackCanUse -> 永远返回true (无CD)
 * 
 * 保持和原函数相同的签名, 这样调用者不会因为栈/寄存器状态异常而崩溃
 * 原函数: bool CheckSkillAttackCanUse(CharacterFiled* this, int skillId, int arg2, int arg3)
 */
static BOOL hookCanUse(void *self, int a1, int a2, int a3) {
    // 直接返回true, 无需调用原函数
    return YES;
}

/**
 * 替代 CheckSkillIsReady -> 永远返回true (无能量限制)
 * 原函数: bool CheckSkillIsReady(CharacterFiled* this, int skillId, int arg2, int arg3)
 */
static BOOL hookIsReady(void *self, int a1, int a2, int a3) {
    return YES;
}

/**
 * 替代 get_limitDamage -> 返回设定的伤害上限
 * 原函数: int get_limitDamage(RuntimeConfig* this)
 * 
 * v10关键优化: hook函数读取g_damageLimit全局变量
 * 这样slider变化时不需要重新hook/patch, 值自动更新!
 */
static int hookLimitDmg(void *self) {
    return g_damageLimit;
}

// ============================================================
// IL2CPP运行时API类型定义
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
// 查找IL2CPP方法 (获取函数机器码地址)
// ============================================================

static void findIL2CPP(void) {
    jlog(@"=== v10.0 IL2CPP Runtime Search ===");
    
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
    Il2CppClassGetName class_name = dlsym(h, "il2cpp_class_get_name");
    
    jlog(@"APIs: domain=%p assemblies=%p image=%p class_count=%p class=%p methods=%p name=%p",
         domain_get, get_assemblies, get_image, class_count, get_class, get_methods, method_name);
    
    if (!domain_get || !method_name) {
        jlog(@"IL2CPP APIs not found");
        return;
    }
    
    void *domain = domain_get();
    jlog(@"domain=%p", domain);
    if (!domain) return;
    
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    jlog(@"assemblies=%p count=%zu", assemblies, assemCount);
    if (!assemblies) return;
    
    int found = 0;
    int totalMethods = 0;
    
    for (size_t a = 0; a < assemCount && found < 3; a++) {
        void *img = get_image(assemblies[a]);
        if (!img) continue;
        size_t cnt = class_count ? class_count(img) : 0;
        
        for (size_t c = 0; c < cnt && found < 3; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            const char *cn = class_name ? class_name(klass) : NULL;
            
            void *iter = NULL;
            void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                totalMethods++;
                const char *n = method_name(m);
                if (!n) continue;
                
                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_infoCanUse) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND CheckSkillAttackCanUse class=%s params=%u", cn ?: "?", pc);
                    g_infoCanUse = m;
                    memcpy(&g_funcCanUse, m, sizeof(void*));
                    jlog(@"  funcAddr=%p", g_funcCanUse);
                    found++;
                }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_infoIsReady) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND CheckSkillIsReady class=%s params=%u", cn ?: "?", pc);
                    g_infoIsReady = m;
                    memcpy(&g_funcIsReady, m, sizeof(void*));
                    jlog(@"  funcAddr=%p", g_funcIsReady);
                    found++;
                }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_infoLimitDmg) {
                    uint32_t pc = param_count ? param_count(m) : 0;
                    jlog(@"FOUND get_limitDamage class=%s params=%u", cn ?: "?", pc);
                    g_infoLimitDmg = m;
                    memcpy(&g_funcLimitDmg, m, sizeof(void*));
                    jlog(@"  funcAddr=%p", g_funcLimitDmg);
                    found++;
                }
            }
        }
    }
    
    jlog(@"Scanned %d methods, found %d targets", totalMethods, found);
    jlog(@"FuncAddr: CanUse=%p IsReady=%p LimitDmg=%p",
         g_funcCanUse, g_funcIsReady, g_funcLimitDmg);
}

// ============================================================
// Dobby Hook 操作
// ============================================================

static void hookCanUseFunc(BOOL enable) {
    if (!g_funcCanUse) { jlog(@"CanUse: funcAddr not found"); return; }
    
    if (enable && !g_cdHooked) {
        int ret = DobbyHook(g_funcCanUse, hookCanUse, (void **)&g_origCanUse);
        if (ret == 0) {
            g_cdHooked = YES;
            jlog(@"CanUse: DobbyHook OK at %p, orig=%p", g_funcCanUse, g_origCanUse);
        } else {
            jlog(@"CanUse: DobbyHook FAILED ret=%d addr=%p", ret, g_funcCanUse);
        }
    } else if (!enable && g_cdHooked) {
        int ret = DobbyDestroyHook(g_funcCanUse);
        if (ret == 0) {
            g_cdHooked = NO;
            g_origCanUse = NULL;
            jlog(@"CanUse: DobbyDestroyHook OK, restored");
        } else {
            jlog(@"CanUse: DobbyDestroyHook FAILED ret=%d", ret);
        }
    }
}

static void hookIsReadyFunc(BOOL enable) {
    if (!g_funcIsReady) { jlog(@"IsReady: funcAddr not found"); return; }
    
    if (enable && !g_energyHooked) {
        int ret = DobbyHook(g_funcIsReady, hookIsReady, (void **)&g_origIsReady);
        if (ret == 0) {
            g_energyHooked = YES;
            jlog(@"IsReady: DobbyHook OK at %p, orig=%p", g_funcIsReady, g_origIsReady);
        } else {
            jlog(@"IsReady: DobbyHook FAILED ret=%d addr=%p", ret, g_funcIsReady);
        }
    } else if (!enable && g_energyHooked) {
        int ret = DobbyDestroyHook(g_funcIsReady);
        if (ret == 0) {
            g_energyHooked = NO;
            g_origIsReady = NULL;
            jlog(@"IsReady: DobbyDestroyHook OK, restored");
        } else {
            jlog(@"IsReady: DobbyDestroyHook FAILED ret=%d", ret);
        }
    }
}

static void hookLimitDmgFunc(BOOL enable) {
    if (!g_funcLimitDmg) { jlog(@"LimitDmg: funcAddr not found"); return; }
    
    if (enable && !g_limitHooked) {
        int ret = DobbyHook(g_funcLimitDmg, hookLimitDmg, (void **)&g_origLimitDmg);
        if (ret == 0) {
            g_limitHooked = YES;
            jlog(@"LimitDmg: DobbyHook OK at %p, orig=%p", g_funcLimitDmg, g_origLimitDmg);
        } else {
            jlog(@"LimitDmg: DobbyHook FAILED ret=%d addr=%p", ret, g_funcLimitDmg);
        }
    } else if (!enable && g_limitHooked) {
        int ret = DobbyDestroyHook(g_funcLimitDmg);
        if (ret == 0) {
            g_limitHooked = NO;
            g_origLimitDmg = NULL;
            jlog(@"LimitDmg: DobbyDestroyHook OK, restored");
        } else {
            jlog(@"LimitDmg: DobbyDestroyHook FAILED ret=%d", ret);
        }
    }
}

static void applyAllHooks(void) {
    if (!g_infoCanUse) findIL2CPP();
    
    if (g_noCD) hookCanUseFunc(YES);
    if (g_noEnergy) hookIsReadyFunc(YES);
    hookLimitDmgFunc(YES);
    
    jlog(@"applyAllHooks done (Dobby inline hook, 和libtool一样!)");
}

// ============================================================
// UI
// ============================================================

static void refreshButtons(void) {
    [g_btnCD setTitle: g_noCD ? @"\U00002705 \u65e0CD: \u5f00" : @"\U0000274c \u65e0CD: \u5173" forState:UIControlStateNormal];
    g_btnCD.backgroundColor = g_noCD ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
    [g_btnEnergy setTitle: g_noEnergy ? @"\U00002705 \u65e0\u80fd\u91cf: \u5f00" : @"\U0000274c \u65e0\u80fd\u91cf: \u5173" forState:UIControlStateNormal];
    g_btnEnergy.backgroundColor = g_noEnergy ? [UIColor colorWithRed:0.15 green:0.75 blue:0.15 alpha:0.95] : [UIColor colorWithRed:0.7 green:0.15 blue:0.15 alpha:0.95];
}

static void layoutPanel(UIView *bv) {
    if (!bv || !g_panel) return;
    CGRect bf=bv.frame, sc=[UIScreen mainScreen].bounds;
    CGFloat pw=260, ph=400;
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
- (void)sliderChanged:(UISlider *)slider;
@end
@implementation JYJHActionHandler
+ (instancetype)shared { static JYJHActionHandler *s; static dispatch_once_t o; dispatch_once(&o,^{s=[[self alloc]init];}); return s; }
- (void)onCD {
    g_noCD=!g_noCD; refreshButtons();
    hookCanUseFunc(g_noCD);
}
- (void)onEnergy {
    g_noEnergy=!g_noEnergy; refreshButtons();
    hookIsReadyFunc(g_noEnergy);
}
- (void)sliderChanged:(UISlider *)s {
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d",g_damageLimit];
    // v10关键优化: slider变化不需要重新hook!
    // hookLimitDmg里面读取g_damageLimit全局变量
    // 只要hook已经设置, 伤害值就自动跟随slider变化
    // 这比v9.2每次slider变化都vm_protect+memcpy好太多了!
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
    for (UIWindow *w in [UIApplication sharedApplication].windows) {
        if (!w.isHidden) return w;
    }
    return nil;
}

static void setupUI(void) {
    UIWindow *win = getKeyWindow();
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,400)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v10.0 (Dobby)"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:15]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    g_btnCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8; [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnCD];
    g_btnEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8; [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnEnergy];
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(16,128,228,20)];
    g_sliderLabel.text=@"\u4f24\u5bb3\u4e0a\u9650: 10000"; g_sliderLabel.textColor=[UIColor whiteColor];
    g_sliderLabel.font=[UIFont systemFontOfSize:13]; [g_panel addSubview:g_sliderLabel];
    g_slider=[[UISlider alloc]initWithFrame:CGRectMake(16,150,228,28)];
    g_slider.minimumValue=100; g_slider.maximumValue=10000; g_slider.value=10000;
    [g_slider addTarget:[JYJHActionHandler shared] action:@selector(sliderChanged:) forControlEvents:UIControlEventValueChanged]; [g_panel addSubview:g_slider];
    g_debugLabel=[[UILabel alloc]initWithFrame:CGRectMake(8,186,244,204)];
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
    jlog(@"========== JYJH v10.0 (Dobby) ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"Strategy: Dobby inline hook (和libtool一样!)");
    
    // 延迟5秒, 等IL2CPP运行时初始化完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying hooks...");
        applyAllHooks();
        
        // 等3秒后再显示UI (让hook先生效)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}
