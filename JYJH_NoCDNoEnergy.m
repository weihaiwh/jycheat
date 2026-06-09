/**
 * 剑影江湖 v9.0 - 直接修改游戏函数机器码 (和libtool一样的策略)
 * 
 * v8.3→v9.0 策略根本性改变:
 * 
 * v8.x的方法: 替换MethodInfo.methodPointer → 闪退修好了, 但功能完全无效!
 *   原因: IL2CPP虚拟方法调用不走MethodInfo.methodPointer
 *         游戏通过vtable直接调用原始函数地址, 指针替换只是改了元数据
 *         元数据改了但实际执行路径不变 → 没有任何效果
 *
 * v9.0的方法: 直接在原始函数地址上写入新代码 (和libtool一样)
 *   这就是libtool注入时"卡顿一下"的原因 — 它在修改游戏代码页的权限
 *   任何调用这个函数的路径(无论vtable、direct call、delegate)都会执行新代码
 *   这才是真正有效的patch方式!
 *
 * 具体做法:
 *   1. IL2CPP API找到MethodInfo → 读取methodPointer → 得到原始函数地址
 *   2. vm_protect把原始函数代码页设为RWX
 *   3. 直接在原始函数地址写入: MOV W0, #1; RET (return true)
 *   4. 保存原始指令用于恢复
 *   5. toggle OFF时恢复原始指令
 *
 * 优势:
 *   - 和libtool完全相同的机制, 经过实战验证有效
 *   - 不需要vm_allocate新代码页
 *   - 不需要MethodInfo指针替换
 *   - 所有调用路径都会走新代码
 */

#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>

extern void sys_icache_invalidate(void *start, size_t len);

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

// IL2CPP MethodInfo指针 (用于读取methodPointer获得函数地址)
static void *g_infoCanUse = NULL;
static void *g_infoIsReady = NULL;
static void *g_infoLimitDmg = NULL;

// 原始函数的机器码地址 (从MethodInfo.methodPointer读出)
static void *g_funcCanUse = NULL;     // CheckSkillAttackCanUse 的机器码地址
static void *g_funcIsReady = NULL;    // CheckSkillIsReady 的机器码地址
static void *g_funcLimitDmg = NULL;   // get_limitDamage 的机器码地址

// 原始函数的前N条指令 (保存用于恢复)
// CheckSkillAttackCanUse / CheckSkillIsReady: 只需覆盖前2条指令 (8字节: MOV W0,#1; RET)
// get_limitDamage: 需要覆盖前2-3条指令 (8-12字节: MOVZ W0,#val; RET)
static uint32_t g_origCanUse[4];      // 保存16字节 (足够覆盖)
static uint32_t g_origIsReady[4];
static uint32_t g_origLimitDmg[4];
static int g_origCanUseLen = 0;       // 保存了多少字节
static int g_origIsReadyLen = 0;
static int g_origLimitDmgLen = 0;

// 补丁状态
static BOOL g_cdPatched = NO;
static BOOL g_energyPatched = NO;
static BOOL g_limitPatched = NO;

// UI
static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

// ============================================================
// 代码页修改工具 (和libtool一样的策略)
// ============================================================

/**
 * patchCode - 在游戏函数的原始地址上直接写入新指令
 * 
 * 这就是libtool的做法:
 * 1. 找到函数所在的代码页
 * 2. vm_protect设为RWX (这就是注入时"卡顿一下"的原因)
 * 3. 直接在函数地址上写新指令
 * 4. sys_icache_invalidate刷新CPU缓存
 * 
 * 所有调用这个函数的路径都会执行新代码, 因为代码本身被改了
 */
static kern_return_t patchCode(void *funcAddr, const uint32_t *newCode, int codeLen) {
    if (!funcAddr) return KERN_INVALID_ADDRESS;
    
    vm_address_t pg = (vm_address_t)funcAddr & ~(vm_page_size - 1);
    
    // 把代码页设为RWX - 这就是libtool注入时卡顿的原因
    // 需要修改整个页的权限, 因为ARM64页最小16384字节
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size, 0,
                                   VM_PROT_READ | VM_PROT_WRITE | VM_PROT_EXECUTE);
    if (kr != KERN_SUCCESS) {
        jlog(@"patchCode vm_protect RWX FAIL addr=%p kr=%d", funcAddr, kr);
        // 尝试 VM_PROT_ALL (包含VM_PROT_COPY)
        kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
        if (kr != KERN_SUCCESS) {
            jlog(@"patchCode vm_protect ALL FAIL kr=%d", kr);
            return kr;
        }
    }
    
    // 直接写入新指令
    memcpy(funcAddr, newCode, codeLen);
    
    // 刷新CPU指令缓存 (ARM64必须, 否则CPU可能还执行旧指令)
    sys_icache_invalidate(funcAddr, codeLen);
    
    // 验证写入
    if (memcmp(funcAddr, newCode, codeLen) == 0) {
        jlog(@"patchCode OK: wrote %d bytes to %p", codeLen, funcAddr);
        return KERN_SUCCESS;
    }
    
    jlog(@"patchCode verify FAIL addr=%p", funcAddr);
    return KERN_FAILURE;
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
    jlog(@"=== v9.0 IL2CPP Runtime Search ===");
    
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
                    // 直接从MethodInfo读methodPointer → 得到游戏函数的真实地址
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
// ARM64代码生成
// ============================================================

// return true: MOV W0, #1; RET (8字节)
static const uint32_t CODE_RETURN_TRUE[2] = { 0x52800020, 0xD65F03C0 };

// return value: MOVZ W0, #val; [MOVK]; RET (8-12字节)
static void makeReturnValue(uint32_t *buf, int value) {
    uint32_t low = value & 0xFFFF;
    uint32_t high = (value >> 16) & 0xFFFF;
    int i = 0;
    buf[i++] = 0x52800000 | (low << 5);
    if (high) buf[i++] = 0x72A00000 | (high << 5);
    buf[i++] = 0xD65F03C0;  // RET
}

// ============================================================
// 应用补丁 - 直接修改游戏函数的机器码
// ============================================================

static void patchCanUse(BOOL enable) {
    if (!g_funcCanUse) { jlog(@"CanUse: funcAddr not found"); return; }
    
    if (enable && !g_cdPatched) {
        // 先读当前函数前4条指令 (用于对比)
        uint32_t *cur = (uint32_t *)g_funcCanUse;
        jlog(@"CanUse current bytes: %08X %08X %08X %08X", cur[0], cur[1], cur[2], cur[3]);
        
        // 保存原始指令 (16字节)
        g_origCanUseLen = 16;
        memcpy(g_origCanUse, g_funcCanUse, g_origCanUseLen);
        jlog(@"CanUse saved orig: %08X %08X %08X %08X", 
             g_origCanUse[0], g_origCanUse[1], g_origCanUse[2], g_origCanUse[3]);
        
        // 直接在函数地址写 MOV W0,#1; RET
        kern_return_t kr = patchCode(g_funcCanUse, CODE_RETURN_TRUE, 8);
        jlog(@"CanUse: patched %p (return true) kr=%d", g_funcCanUse, kr);
        
        if (kr == KERN_SUCCESS) {
            g_cdPatched = YES;
            uint32_t *v = (uint32_t *)g_funcCanUse;
            jlog(@"CanUse verify: %08X %08X", v[0], v[1]);
        }
    } else if (!enable && g_cdPatched) {
        // 恢复原始指令
        kern_return_t kr = patchCode(g_funcCanUse, g_origCanUse, g_origCanUseLen);
        jlog(@"CanUse: restored %p kr=%d", g_funcCanUse, kr);
        g_cdPatched = NO;
    }
}

static void patchIsReady(BOOL enable) {
    if (!g_funcIsReady) { jlog(@"IsReady: funcAddr not found"); return; }
    
    if (enable && !g_energyPatched) {
        uint32_t *cur = (uint32_t *)g_funcIsReady;
        jlog(@"IsReady current bytes: %08X %08X %08X %08X", cur[0], cur[1], cur[2], cur[3]);
        
        g_origIsReadyLen = 16;
        memcpy(g_origIsReady, g_funcIsReady, g_origIsReadyLen);
        jlog(@"IsReady saved orig: %08X %08X %08X %08X",
             g_origIsReady[0], g_origIsReady[1], g_origIsReady[2], g_origIsReady[3]);
        
        kern_return_t kr = patchCode(g_funcIsReady, CODE_RETURN_TRUE, 8);
        jlog(@"IsReady: patched %p (return true) kr=%d", g_funcIsReady, kr);
        
        if (kr == KERN_SUCCESS) {
            g_energyPatched = YES;
            uint32_t *v = (uint32_t *)g_funcIsReady;
            jlog(@"IsReady verify: %08X %08X", v[0], v[1]);
        }
    } else if (!enable && g_energyPatched) {
        kern_return_t kr = patchCode(g_funcIsReady, g_origIsReady, g_origIsReadyLen);
        jlog(@"IsReady: restored %p kr=%d", g_funcIsReady, kr);
        g_energyPatched = NO;
    }
}

static void patchLimitDmgValue(int value) {
    if (!g_funcLimitDmg) { jlog(@"LimitDmg: funcAddr not found"); return; }
    
    if (!g_limitPatched) {
        uint32_t *cur = (uint32_t *)g_funcLimitDmg;
        jlog(@"LimitDmg current bytes: %08X %08X %08X %08X", cur[0], cur[1], cur[2], cur[3]);
        
        g_origLimitDmgLen = 16;
        memcpy(g_origLimitDmg, g_funcLimitDmg, g_origLimitDmgLen);
        jlog(@"LimitDmg saved orig: %08X %08X %08X %08X",
             g_origLimitDmg[0], g_origLimitDmg[1], g_origLimitDmg[2], g_origLimitDmg[3]);
    }
    
    uint32_t code[4] = {0};
    makeReturnValue(code, value);
    int codeLen = (value > 0xFFFF) ? 12 : 8;
    
    kern_return_t kr = patchCode(g_funcLimitDmg, code, codeLen);
    jlog(@"LimitDmg: patched %p (return %d) kr=%d len=%d", g_funcLimitDmg, value, kr, codeLen);
    
    if (kr == KERN_SUCCESS) {
        g_limitPatched = YES;
    }
}

static void restoreLimitDmg(void) {
    if (!g_limitPatched || !g_funcLimitDmg) return;
    
    kern_return_t kr = patchCode(g_funcLimitDmg, g_origLimitDmg, g_origLimitDmgLen);
    jlog(@"LimitDmg: restored %p kr=%d", g_funcLimitDmg, kr);
    g_limitPatched = NO;
}

static void applyAllPatches(void) {
    if (!g_infoCanUse) findIL2CPP();
    
    if (g_noCD) patchCanUse(YES);
    if (g_noEnergy) patchIsReady(YES);
    patchLimitDmgValue(g_damageLimit);
    
    jlog(@"applyAllPatches done (直接修改函数机器码, 和libtool一样)");
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
    patchCanUse(g_noCD);
}
- (void)onEnergy {
    g_noEnergy=!g_noEnergy; refreshButtons();
    patchIsReady(g_noEnergy);
}
- (void)sliderChanged:(UISlider *)s {
    g_damageLimit=(int)s.value;
    g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d",g_damageLimit];
    patchLimitDmgValue(g_damageLimit);
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
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v9.2"; title.textColor=[UIColor cyanColor];
    title.font=[UIFont boldSystemFontOfSize:15]; title.textAlignment=NSTextAlignmentCenter; [g_panel addSubview:title];
    g_btnCD=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnCD.frame=CGRectMake(16,42,228,36);
    g_btnCD.layer.cornerRadius=8; [g_btnCD addTarget:[JYJHActionHandler shared] action:@selector(onCD) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnCD];
    g_btnEnergy=[UIButton buttonWithType:UIButtonTypeCustom]; g_btnEnergy.frame=CGRectMake(16,84,228,36);
    g_btnEnergy.layer.cornerRadius=8; [g_btnEnergy addTarget:[JYJHActionHandler shared] action:@selector(onEnergy) forControlEvents:UIControlEventTouchUpInside]; [g_panel addSubview:g_btnEnergy];
    g_sliderLabel=[[UILabel alloc]initWithFrame:CGRectMake(16,128,228,20)];
    g_sliderLabel.text=@"伤害上限: 10000"; g_sliderLabel.textColor=[UIColor whiteColor];
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
    jlog(@"========== JYJH v9.2 ==========");
    jlog(@"iOS %@", [[UIDevice currentDevice] systemVersion]);
    jlog(@"Bundle %@", [[NSBundle mainBundle] bundleIdentifier]);
    jlog(@"Strategy: 直接修改游戏函数机器码 (和libtool一样)");
    
    // 延迟5秒, 等IL2CPP运行时初始化完成
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        jlog(@"5s delay done, applying patches...");
        applyAllPatches();
        
        // 等3秒后再显示UI (让patch先生效)
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(3.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
            setupUI();
        });
    });
}