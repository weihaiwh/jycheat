/**
 * 剑影江湖 v1.10.1 - v7.3
 * 不覆盖原函数，修改MethodInfo->methodPointer指向我们分配的代码
 * v7.2闪退原因：覆盖原函数STP指令，callee-saved寄存器未保存
 */
#import <mach-o/dyld.h>
#import <mach/mach.h>
#import <dispatch/dispatch.h>
#import <UIKit/UIKit.h>
#import <stdio.h>
#import <string.h>
#import <dlfcn.h>
#import <sys/mman.h>

extern void sys_icache_invalidate(void *start, size_t len);

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

static BOOL g_noCD = YES;
static BOOL g_noEnergy = YES;
static int g_damageLimit = 10000;
static void *g_infoCanUse = NULL;
static void *g_infoIsReady = NULL;
static void *g_infoLimitDmg = NULL;
static void *g_origPtrCanUse = NULL;
static void *g_origPtrIsReady = NULL;
static void *g_origPtrLimitDmg = NULL;
static void *g_codeMem = NULL;
static void *g_codeLimitDmg = NULL;

static UIView *g_panel = nil;
static UIButton *g_btnCD = nil;
static UIButton *g_btnEnergy = nil;
static UISlider *g_slider = nil;
static UILabel *g_sliderLabel = nil;
static BOOL g_panelOpen = NO;

static kern_return_t patchMem(void *addr, const void *data, size_t sz) {
    if (!addr) return KERN_INVALID_ADDRESS;
    vm_address_t pg = (vm_address_t)addr & ~(vm_page_size - 1);
    kern_return_t kr = vm_protect(mach_task_self(), pg, vm_page_size * 2, 0, VM_PROT_READ | VM_PROT_WRITE | VM_PROT_COPY);
    if (kr != KERN_SUCCESS) kr = vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_ALL);
    if (kr != KERN_SUCCESS) return kr;
    memcpy(addr, data, sz);
    sys_icache_invalidate(addr, sz);
    vm_protect(mach_task_self(), pg, vm_page_size, 0, VM_PROT_READ | VM_PROT_EXECUTE);
    return KERN_SUCCESS;
}

typedef void* (*Il2CppDomainGet)(void);
typedef void** (*Il2CppDomainGetAssemblies)(void*, size_t*);
typedef void* (*Il2CppAssemblyGetImage)(void*);
typedef size_t (*Il2CppImageGetClassCount)(void*);
typedef void* (*Il2CppImageGetClass)(void*, size_t);
typedef void* (*Il2CppClassGetMethods)(void*, void**);
typedef const char* (*Il2CppMethodGetName)(void*);

static void* getMethodPointer(void *methodInfo) {
    if (!methodInfo) return NULL;
    void *ptr = NULL;
    memcpy(&ptr, methodInfo, sizeof(void*));
    if (ptr && (uint64_t)ptr > 0x100000000ULL) {
        vm_size_t outSize = 0; uint32_t test;
        kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)ptr, 4, (vm_address_t)&test, &outSize);
        if (kr == KERN_SUCCESS && test != 0 && test != 0xFFFFFFFF) return ptr;
    }
    memcpy(&ptr, ((char*)methodInfo) + 8, sizeof(void*));
    if (ptr && (uint64_t)ptr > 0x100000000ULL) {
        vm_size_t outSize = 0; uint32_t test;
        kern_return_t kr = vm_read_overwrite(mach_task_self(), (vm_address_t)ptr, 4, (vm_address_t)&test, &outSize);
        if (kr == KERN_SUCCESS && test != 0 && test != 0xFFFFFFFF) return ptr;
    }
    return NULL;
}

static void findIL2CPP(void) {
    jlog(@"=== v7.3 ===");
    void *h = dlopen(NULL, RTLD_LAZY);
    Il2CppDomainGet domain_get = dlsym(h, "il2cpp_domain_get");
    Il2CppDomainGetAssemblies get_assemblies = dlsym(h, "il2cpp_domain_get_assemblies");
    Il2CppAssemblyGetImage get_image = dlsym(h, "il2cpp_assembly_get_image");
    Il2CppImageGetClassCount class_count = dlsym(h, "il2cpp_image_get_class_count");
    Il2CppImageGetClass get_class = dlsym(h, "il2cpp_image_get_class");
    Il2CppClassGetMethods get_methods = dlsym(h, "il2cpp_class_get_methods");
    Il2CppMethodGetName method_name = dlsym(h, "il2cpp_method_get_name");
    if (!domain_get || !method_name) { jlog(@"No APIs"); return; }
    void *domain = domain_get();
    size_t assemCount = 0;
    void **assemblies = get_assemblies(domain, &assemCount);
    int found = 0;
    for (size_t a = 0; a < assemCount && found < 3; a++) {
        void *img = get_image(assemblies[a]);
        size_t cnt = class_count(img);
        for (size_t c = 0; c < cnt && found < 3; c++) {
            void *klass = get_class(img, c);
            if (!klass) continue;
            void *iter = NULL; void *m = NULL;
            while ((m = get_methods(klass, &iter)) != NULL) {
                const char *n = method_name(m);
                if (!n) continue;
                if (strcmp(n, "CheckSkillAttackCanUse") == 0 && !g_infoCanUse) { g_infoCanUse = m; g_origPtrCanUse = getMethodPointer(m); jlog(@"CanUse=%p", g_origPtrCanUse); found++; }
                else if (strcmp(n, "CheckSkillIsReady") == 0 && !g_infoIsReady) { g_infoIsReady = m; g_origPtrIsReady = getMethodPointer(m); jlog(@"IsReady=%p", g_origPtrIsReady); found++; }
                else if (strcmp(n, "get_limitDamage") == 0 && !g_infoLimitDmg) { g_infoLimitDmg = m; g_origPtrLimitDmg = getMethodPointer(m); jlog(@"LimitDmg=%p", g_origPtrLimitDmg); found++; }
            }
        }
    }
    jlog(@"Found: CanUse=%p IsReady=%p LimitDmg=%p", g_origPtrCanUse, g_origPtrIsReady, g_origPtrLimitDmg);
}

static int writeReturnTrue(void *addr) {
    uint32_t *c = (uint32_t *)addr; int i = 0;
    c[i++] = 0xA9B97BFD; c[i++] = 0xA90153F3; c[i++] = 0xA9024BF5;
    c[i++] = 0xA90343F7; c[i++] = 0xA9043BF9; c[i++] = 0xA90533FB;
    c[i++] = 0x52800020;
    c[i++] = 0xA94153F3; c[i++] = 0xA9424BF5; c[i++] = 0xA94343F7;
    c[i++] = 0xA9443BF9; c[i++] = 0xA94533FB; c[i++] = 0xA8C17BFD;
    c[i++] = 0xD65F03C0;
    sys_icache_invalidate(addr, i * 4);
    return i * 4;
}

static int writeReturnValue(void *addr, int value) {
    uint32_t *c = (uint32_t *)addr; int i = 0;
    c[i++] = 0xA9B97BFD; c[i++] = 0xA90153F3; c[i++] = 0xA9024BF5;
    c[i++] = 0xA90343F7; c[i++] = 0xA9043BF9; c[i++] = 0xA90533FB;
    uint32_t low = value & 0xFFFF; uint32_t high = (value >> 16) & 0xFFFF;
    c[i++] = 0x52800000 | (low << 5);
    if (high) c[i++] = 0x72A00000 | (high << 5);
    c[i++] = 0xA94153F3; c[i++] = 0xA9424BF5; c[i++] = 0xA94343F7;
    c[i++] = 0xA9443BF9; c[i++] = 0xA94533FB; c[i++] = 0xA8C17BFD;
    c[i++] = 0xD65F03C0;
    sys_icache_invalidate(addr, i * 4);
    return i * 4;
}

static void applyPatches(void) {
    if (!g_infoCanUse) findIL2CPP();
    if (!g_codeMem) {
        g_codeMem = mmap(NULL, 4096, PROT_READ|PROT_WRITE|PROT_EXEC, MAP_PRIVATE|MAP_ANONYMOUS|MAP_JIT, -1, 0);
        if (g_codeMem == MAP_FAILED) { jlog(@"mmap fail"); g_codeMem = NULL; return; }
        jlog(@"codeMem=%p", g_codeMem);
    }
    void *c1 = g_codeMem;
    writeReturnTrue(c1);
    void *c2 = (char*)g_codeMem + 64;
    writeReturnTrue(c2);
    g_codeLimitDmg = (char*)g_codeMem + 128;
    if (g_noCD && g_infoCanUse) {
        kern_return_t kr = patchMem(g_infoCanUse, &c1, sizeof(void*));
        jlog(@"CanUse->%p kr=%d", c1, kr);
    }
    if (g_noEnergy && g_infoIsReady) {
        kern_return_t kr = patchMem(g_infoIsReady, &c2, sizeof(void*));
        jlog(@"IsReady->%p kr=%d", c2, kr);
    }
}

static void patchLimitDamage(int value) {
    if (!g_infoLimitDmg || !g_codeMem) return;
    writeReturnValue(g_codeLimitDmg, value);
    kern_return_t kr = patchMem(g_infoLimitDmg, &g_codeLimitDmg, sizeof(void*));
    jlog(@"LimitDmg->%p val=%d kr=%d", g_codeLimitDmg, value, kr);
}

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
- (void)onCD { g_noCD=!g_noCD; refreshButtons(); if(g_noCD) applyPatches(); else if(g_infoCanUse&&g_origPtrCanUse) patchMem(g_infoCanUse,&g_origPtrCanUse,sizeof(void*)); }
- (void)onEnergy { g_noEnergy=!g_noEnergy; refreshButtons(); if(g_noEnergy) applyPatches(); else if(g_infoIsReady&&g_origPtrIsReady) patchMem(g_infoIsReady,&g_origPtrIsReady,sizeof(void*)); }
- (void)sliderChanged:(UISlider *)s { g_damageLimit=(int)s.value; g_sliderLabel.text=[NSString stringWithFormat:@"\u4f24\u5bb3\u4e0a\u9650: %d",g_damageLimit]; patchLimitDamage(g_damageLimit); }
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

static void setupUI(void) {
    UIWindow *win = nil;
    for (UIWindow *w in [UIApplication sharedApplication].windows) if (w.isKeyWindow && !w.isHidden) { win = w; break; }
    if (!win) for (UIWindow *w in [UIApplication sharedApplication].windows) if (!w.isHidden) { win = w; break; }
    if (!win) { dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(1.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{setupUI();}); return; }
    JYJHBallView *ball = [[JYJHBallView alloc] init]; [win addSubview:ball];
    g_panel=[[UIView alloc]initWithFrame:CGRectMake(0,0,260,400)];
    g_panel.backgroundColor=[UIColor colorWithRed:0.08 green:0.08 blue:0.12 alpha:0.98];
    g_panel.layer.cornerRadius=14; g_panel.hidden=YES; [win addSubview:g_panel];
    UILabel *title=[[UILabel alloc]initWithFrame:CGRectMake(0,10,260,24)];
    title.text=@"\u5251\u5f71\u6c5f\u6e56 v7.3"; title.textColor=[UIColor cyanColor];
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

__attribute__((constructor))
static void initialize(void) {
    g_debugLines=[NSMutableArray new];
    jlog(@"========== JYJH v7.3 ==========");
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(int64_t)(5.0*NSEC_PER_SEC)),dispatch_get_main_queue(),^{
        applyPatches();
        patchLimitDamage(g_damageLimit);
        setupUI();
    });
}
